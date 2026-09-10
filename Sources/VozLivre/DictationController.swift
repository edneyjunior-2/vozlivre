import AppKit
import AVFoundation

/// Orquestra o fluxo de ditado: atalho → gravar → transcrever → colar, atualizando o estado.
@MainActor
final class DictationController {

    private let recorder = AudioRecorder()
    private let engine: TranscriptionEngine = WhisperTranscriptionEngine()
    private(set) var gravando = false

    /// Callbacks para a UI refletir o estado e mensagens.
    var onEstado: ((AppState) -> Void)?
    var onMensagem: ((String) -> Void)?

    var modo: ModoAtivacao {
        get {
            let raw = UserDefaults.standard.string(forKey: "modoAtivacao") ?? ModoAtivacao.pushToTalk.rawValue
            return ModoAtivacao(rawValue: raw) ?? .pushToTalk
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "modoAtivacao") }
    }

    // MARK: Hooks de atalho

    /// Pressionou o atalho.
    func atalhoPressionado() {
        switch modo {
        case .pushToTalk:
            iniciarGravacao()
        case .toggle:
            gravando ? finalizarGravacao() : iniciarGravacao()
        }
    }

    /// Soltou o atalho (só importa no push-to-talk).
    func atalhoSolto() {
        if modo == .pushToTalk { finalizarGravacao() }
    }

    /// Duplo toque no atalho: alterna direto, ignorando o modo configurado — não
    /// existe "segurar" quando o gatilho são dois toques.
    func alternarGravacao() {
        gravando ? finalizarGravacao() : iniciarGravacao()
    }

    // MARK: Fluxo

    private func iniciarGravacao() {
        guard !gravando else { return }

        // Verifica permissões antes de gravar.
        guard Permissions.microfoneAutorizado else {
            onMensagem?("Microfone bloqueado — autorize nos Ajustes do Sistema.")
            Task { _ = await Permissions.pedirMicrofone() }
            return
        }
        guard Permissions.acessibilidadeAutorizada else {
            onMensagem?("Acessibilidade desativada — necessária para colar o texto.")
            Permissions.pedirAcessibilidade()
            return
        }

        // Começa a carregar o modelo AGORA, junto com a gravação: a carga corre em
        // paralelo com a fala e some da espera, em vez de ser paga no fim.
        WhisperMotor.shared.preaquecer()

        do {
            try recorder.iniciar()
            gravando = true
            Feedback.tocar(.comecou)
            if HUDPreferencia.ativo {
                VoiceHUD.shared.mostrarOuvindo { [weak recorder = self.recorder] in recorder?.nivelAtual ?? 0 }
            }
            onEstado?(.gravando)
        } catch {
            VoiceHUD.shared.esconder()
            onMensagem?("Não foi possível iniciar a gravação: \(error.localizedDescription)")
            onEstado?(.ocioso)
        }
    }

    private func finalizarGravacao() {
        guard gravando else { return }
        gravando = false
        Feedback.tocar(.parou)

        let coletado: (buffers: [AVAudioPCMBuffer], format: AVAudioFormat)
        do {
            coletado = try recorder.pararEColetar()
        } catch {
            VoiceHUD.shared.esconder()
            onMensagem?("Nenhuma fala capturada.")
            onEstado?(.ocioso)
            return
        }

        VoiceHUD.shared.mostrarTranscrevendo()
        onEstado?(.transcrevendo)
        // Tempo de parede de verdade: do fim da fala até o texto na tela. É o número
        // que o usuário sente — o cronômetro interno do motor ignora conversão de
        // áudio, carga e inserção do texto.
        let inicio = Date()
        Task {
            do {
                let texto = try await engine.transcrever(buffers: coletado.buffers,
                                                          inputFormat: coletado.format)
                TextInjector.inserir(texto)
                let ms = Int(Date().timeIntervalSince(inicio) * 1000)
                onMensagem?("Inserido em \(ms) ms: \(texto.prefix(32))…")
            } catch {
                onMensagem?("Transcrição falhou: \(error)")
            }
            VoiceHUD.shared.esconder()
            onEstado?(.ocioso)
        }
    }
}


/// Liga/desliga a pílula flutuante com a onda de voz.
enum HUDPreferencia {
    private static let chave = "mostrarHUD"

    /// Ligada por padrão — é o sinal principal de "estou ouvindo" no modo mãos livres.
    static var ativo: Bool {
        get { UserDefaults.standard.object(forKey: chave) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: chave) }
    }
}
