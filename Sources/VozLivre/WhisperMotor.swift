import Foundation
import CWhisper

/// Motor de transcrição rodando DENTRO do app, com o modelo carregado uma vez só.
///
/// Antes, cada ditado abria um programa externo que carregava 1 GB do zero, usava
/// por meio segundo e morria — só esse carregamento respondia por mais da metade da
/// espera. Aqui o modelo é carregado uma vez e reaproveitado.
///
/// A carga começa no instante em que a gravação começa (`preaquecer`), então ela
/// acontece **enquanto a pessoa ainda está falando** e desaparece da conta. Por isso
/// não é preciso manter 2 GB presos o dia inteiro: o modelo é solto após um tempo
/// parado — ou na hora, se o sistema avisar que está com pouca memória — e a próxima
/// carga se esconde atrás da fala seguinte.
final class WhisperMotor: @unchecked Sendable {
    static let shared = WhisperMotor()

    enum MotorError: Error, CustomStringConvertible {
        case modeloNaoEncontrado
        case falhouAoCarregar
        case falhouATranscrever(Int32)
        case vazio

        var description: String {
            switch self {
            case .modeloNaoEncontrado:   return "Modelo de transcrição não encontrado no app."
            case .falhouAoCarregar:      return "Não foi possível carregar o modelo de transcrição."
            case .falhouATranscrever(let c): return "Falha na transcrição (código \(c))."
            case .vazio:                 return "Nenhuma fala detectada."
            }
        }
    }

    /// Uma fila serial para tudo: um `whisper_context` não aguenta duas transcrições
    /// ao mesmo tempo, e é aqui que a carga do modelo também acontece.
    private let fila = DispatchQueue(label: "app.vozlivre.whisper", qos: .userInitiated)

    private var contexto: OpaquePointer?
    private var ultimoUso = Date()

    /// Quanto tempo o modelo fica na memória sem uso antes de ser solto.
    private let ocioMaximo: TimeInterval = 10 * 60
    private var timerOcio: DispatchSourceTimer?
    private var monitorDeMemoria: DispatchSourceMemoryPressure?

    private init() {
        observarPressaoDeMemoria()
    }

    // MARK: Modelo

    private var caminhoDoModelo: String? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "ggml-large-v3-q5_0", withExtension: "bin")
            ?? bundle.url(forResource: "ggml-large-v3", withExtension: "bin")
        return url?.path
    }

    private var caminhoDoVAD: String? {
        guard let url = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    /// Começa a carregar o modelo sem bloquear quem chamou.
    ///
    /// Chamado quando a gravação começa: a carga corre em paralelo com a fala, então
    /// quando o usuário termina o modelo já está pronto.
    func preaquecer() {
        fila.async { [weak self] in
            _ = try? self?.contextoPronto()
        }
    }

    /// Devolve o contexto, carregando se necessário. Só roda dentro da fila.
    private func contextoPronto() throws -> OpaquePointer {
        if let contexto {
            ultimoUso = Date()
            return contexto
        }
        guard let caminho = caminhoDoModelo else { throw MotorError.modeloNaoEncontrado }

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true

        guard let novo = whisper_init_from_file_with_params(caminho, params) else {
            throw MotorError.falhouAoCarregar
        }
        contexto = novo
        ultimoUso = Date()
        agendarLiberacaoPorOcio()
        return novo
    }

    // MARK: Transcrição

    /// Transcreve amostras já em 16 kHz mono float. Bloqueia até terminar.
    func transcrever(amostras: [Float], prompt: String, idioma: String = "pt") throws -> String {
        try fila.sync {
            let ctx = try contextoPronto()

            var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false
            params.no_timestamps = true
            params.single_segment = false
            params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

            // As strings precisam continuar vivas durante toda a chamada de whisper_full —
            // por isso os ponteiros são criados aqui e liberados só no fim.
            let cIdioma = strdup(idioma)
            let cPrompt = strdup(prompt)
            let cVAD = caminhoDoVAD.map { strdup($0) } ?? nil
            defer {
                free(cIdioma)
                free(cPrompt)
                if let cVAD { free(cVAD) }
            }

            params.language = UnsafePointer(cIdioma)
            params.initial_prompt = UnsafePointer(cPrompt)

            // Detecção de fala: sem ela o modelo preenche silêncio com frases inventadas.
            if let cVAD {
                params.vad = true
                params.vad_model_path = UnsafePointer(cVAD)
                var vad = whisper_vad_default_params()
                vad.speech_pad_ms = 200   // 30ms (padrão) corta consoante nas bordas
                params.vad_params = vad
            }

            let status = amostras.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
            }
            guard status == 0 else { throw MotorError.falhouATranscrever(status) }

            var texto = ""
            for i in 0..<whisper_full_n_segments(ctx) {
                if let trecho = whisper_full_get_segment_text(ctx, i) {
                    texto += String(cString: trecho)
                }
            }

            ultimoUso = Date()
            agendarLiberacaoPorOcio()

            let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limpo.isEmpty else { throw MotorError.vazio }
            return limpo
        }
    }

    // MARK: Liberação de memória

    /// Solta o modelo. Seguro chamar a qualquer momento — a fila garante que não há
    /// transcrição em andamento.
    func liberar() {
        fila.async { [weak self] in
            guard let self, let ctx = self.contexto else { return }
            whisper_free(ctx)
            self.contexto = nil
            self.timerOcio?.cancel()
            self.timerOcio = nil
        }
    }

    private func agendarLiberacaoPorOcio() {
        timerOcio?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: fila)
        timer.schedule(deadline: .now() + ocioMaximo)
        timer.setEventHandler { [weak self] in
            guard let self, let ctx = self.contexto else { return }
            guard Date().timeIntervalSince(self.ultimoUso) >= self.ocioMaximo else { return }
            whisper_free(ctx)
            self.contexto = nil
        }
        timer.resume()
        timerOcio = timer
    }

    /// Num Mac de 16 GB, esperar o timer pode ser tarde demais: se o sistema avisar
    /// que está apertado, o modelo sai da memória na hora.
    private func observarPressaoDeMemoria() {
        let fonte = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                            queue: fila)
        fonte.setEventHandler { [weak self] in
            guard let self, let ctx = self.contexto else { return }
            whisper_free(ctx)
            self.contexto = nil
        }
        fonte.resume()
        monitorDeMemoria = fonte
    }
}
