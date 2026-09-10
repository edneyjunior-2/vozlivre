@preconcurrency import AVFoundation
import Speech

/// Protocolo do engine de transcrição — plugável para trocar o motor depois
/// (Apple SpeechAnalyzer na v1; Whisper/WhisperKit numa iteração futura).
@MainActor
protocol TranscriptionEngine {
    /// Transcreve os buffers capturados e devolve o texto em pt-BR.
    func transcrever(buffers: [AVAudioPCMBuffer], inputFormat: AVAudioFormat) async throws -> String
}

enum TranscriptionError: Error, CustomStringConvertible {
    case localeIndisponivel
    case formatoIndisponivel
    case conversaoFalhou
    case vazio

    var description: String {
        switch self {
        case .localeIndisponivel: return "Português-BR não está disponível para transcrição neste Mac."
        case .formatoIndisponivel: return "Não foi possível obter um formato de áudio compatível."
        case .conversaoFalhou:     return "Falha ao converter o áudio para o transcritor."
        case .vazio:               return "Nenhuma fala detectada."
        }
    }
}

/// Implementação on-device usando o SpeechAnalyzer/SpeechTranscriber nativos do macOS 26.
/// 100% offline — nenhuma chamada de rede (AC4 / restrição de privacidade).
@MainActor
final class AppleSpeechEngine: TranscriptionEngine {

    private let locale = Locale(identifier: "pt-BR")

    func transcrever(buffers: [AVAudioPCMBuffer], inputFormat: AVAudioFormat) async throws -> String {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        try await garantirModeloInstalado(para: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.formatoIndisponivel
        }

        // Stream de entrada para o analyzer.
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        // Coletor de resultados rodando em paralelo ao envio do áudio.
        let coletor = Task { () -> String in
            var texto = ""
            for try await resultado in transcriber.results {
                texto += String(resultado.text.characters)
            }
            return texto
        }

        try await analyzer.start(inputSequence: inputSequence)

        // Converte cada buffer para o formato do analyzer e envia.
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw TranscriptionError.conversaoFalhou
        }
        for buffer in buffers {
            if let convertido = Self.converter(buffer, com: converter, para: analyzerFormat) {
                inputBuilder.yield(AnalyzerInput(buffer: convertido))
            }
        }
        inputBuilder.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let texto = try await coletor.value
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { throw TranscriptionError.vazio }
        return limpo
    }

    /// Garante que o modelo de pt-BR esteja instalado on-device (baixa no 1º uso).
    private func garantirModeloInstalado(para transcriber: SpeechTranscriber) async throws {
        let suportados = await SpeechTranscriber.supportedLocales
        let suportaPT = suportados.contains { $0.identifier(.bcp47).hasPrefix("pt-BR") }
        guard suportaPT else { throw TranscriptionError.localeIndisponivel }

        let instalados = await SpeechTranscriber.installedLocales
        let jaInstalado = instalados.contains { $0.identifier(.bcp47).hasPrefix("pt-BR") }
        if !jaInstalado {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
    }

    private static func converter(_ buffer: AVAudioPCMBuffer,
                                  com converter: AVAudioConverter,
                                  para destino: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = destino.sampleRate / buffer.format.sampleRate
        let capacidade = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let saida = AVAudioPCMBuffer(pcmFormat: destino, frameCapacity: capacidade) else { return nil }

        var enviado = false
        let status = converter.convert(to: saida, error: nil) { _, outStatus in
            if enviado {
                outStatus.pointee = .noDataNow
                return nil
            }
            enviado = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .haveData || status == .inputRanDry ? saida : nil
    }
}
