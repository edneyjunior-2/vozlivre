@preconcurrency import AVFoundation

/// Escreve buffers PCM num arquivo .wav em disco, incrementalmente — usado pra gravar
/// o áudio bruto (mic e sistema) enquanto a aula acontece, sem acumular tudo em memória.
final class AudioFileWriter {
    private var arquivo: AVAudioFile?
    private(set) var erro: Error?
    private(set) var temConteudo = false
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func escrever(_ buffer: AVAudioPCMBuffer) {
        guard erro == nil else { return }

        if arquivo == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false
            ]
            do {
                arquivo = try AVAudioFile(forWriting: url,
                                          settings: settings,
                                          commonFormat: buffer.format.commonFormat,
                                          interleaved: buffer.format.isInterleaved)
            } catch {
                self.erro = error
                return
            }
        }

        do {
            try arquivo?.write(from: buffer)
            temConteudo = true
        } catch {
            self.erro = error
        }
    }

    /// Fecha o arquivo, garantindo que o cabeçalho .wav fique correto ANTES de outro
    /// processo (o whisper-cli) tentar ler — sem isso, o arquivo fica com duração 0.
    func fechar() {
        arquivo = nil
    }
}
