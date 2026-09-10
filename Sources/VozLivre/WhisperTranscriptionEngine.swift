@preconcurrency import AVFoundation

/// Liga o fluxo de ditado ao motor embutido: junta o áudio gravado, converte para o
/// formato que o Whisper espera (16 kHz mono) e devolve o texto.
///
/// Não passa mais por arquivo em disco nem por programa externo — o áudio vai direto
/// da memória para o motor.
@MainActor
final class WhisperTranscriptionEngine: TranscriptionEngine {

    func transcrever(buffers: [AVAudioPCMBuffer], inputFormat: AVAudioFormat) async throws -> String {
        guard !buffers.isEmpty else { throw TranscriptionError.vazio }

        let amostras = try AudioParaWhisper.amostras16kMono(de: buffers, formato: inputFormat)
        guard amostras.count > 1600 else { throw TranscriptionError.vazio }   // < 0,1s não é fala

        let prompt = Vocabulario.prompt()
        return try await withCheckedThrowingContinuation { continuacao in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let texto = try WhisperMotor.shared.transcrever(amostras: amostras, prompt: prompt)
                    continuacao.resume(returning: texto)
                } catch {
                    continuacao.resume(throwing: error)
                }
            }
        }
    }
}

/// Conversão do áudio do microfone para o formato do Whisper.
enum AudioParaWhisper {

    /// O Whisper trabalha sempre em 16 kHz mono. O microfone entrega normalmente
    /// 48 kHz e às vezes estéreo.
    private static let taxaDestino: Double = 16_000

    static func amostras16kMono(de buffers: [AVAudioPCMBuffer],
                                formato: AVAudioFormat) throws -> [Float] {
        guard let destino = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: taxaDestino,
                                          channels: 1,
                                          interleaved: false) else {
            throw TranscriptionError.formatoIndisponivel
        }

        // Junta tudo num buffer só antes de converter. Converter buffer a buffer faria
        // o reamostrador reiniciar em cada pedaço e deixaria estalos nas emendas.
        let totalDeQuadros = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard totalDeQuadros > 0,
              let inteiro = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: totalDeQuadros) else {
            throw TranscriptionError.vazio
        }
        inteiro.frameLength = 0
        for buffer in buffers {
            guard let origem = buffer.floatChannelData,
                  let alvo = inteiro.floatChannelData else { continue }
            let deslocamento = Int(inteiro.frameLength)
            let quadros = Int(buffer.frameLength)
            for canal in 0..<Int(formato.channelCount) {
                alvo[canal].advanced(by: deslocamento).update(from: origem[canal], count: quadros)
            }
            inteiro.frameLength += buffer.frameLength
        }

        if formato.sampleRate == taxaDestino && formato.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: inteiro.floatChannelData![0],
                                             count: Int(inteiro.frameLength)))
        }

        guard let conversor = AVAudioConverter(from: formato, to: destino) else {
            throw TranscriptionError.conversaoFalhou
        }
        let proporcao = taxaDestino / formato.sampleRate
        let capacidade = AVAudioFrameCount(Double(inteiro.frameLength) * proporcao) + 1024
        guard let saida = AVAudioPCMBuffer(pcmFormat: destino, frameCapacity: capacidade) else {
            throw TranscriptionError.conversaoFalhou
        }

        var entregue = false
        var erro: NSError?
        let status = conversor.convert(to: saida, error: &erro) { _, outStatus in
            if entregue {
                outStatus.pointee = .endOfStream
                return nil
            }
            entregue = true
            outStatus.pointee = .haveData
            return inteiro
        }
        guard status != .error, erro == nil, saida.frameLength > 0,
              let dados = saida.floatChannelData else {
            throw TranscriptionError.conversaoFalhou
        }
        return Array(UnsafeBufferPointer(start: dados[0], count: Int(saida.frameLength)))
    }
}
