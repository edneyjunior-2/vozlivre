@preconcurrency import AVFoundation

/// Captura de áudio do microfone via AVAudioEngine (AC3).
/// Acumula os buffers no formato nativo do microfone; a conversão para o formato
/// que o transcritor exige é feita depois (fora da thread de render, evitando o
/// crash conhecido do AVAudioConverter em tempo real).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var buffers: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private(set) var inputFormat: AVAudioFormat?

    // Nível de voz atual (0…1) para o HUD desenhar a onda. Guardado numa propriedade
    // com trava em vez de callback: quem desenha já roda num timer próprio, então
    // basta ler o valor mais recente — nada atravessa a thread de áudio.
    private var nivel: Float = 0
    var nivelAtual: Float {
        lock.lock(); defer { lock.unlock() }
        return nivel
    }

    enum RecorderError: Error {
        case engineFalhou(String)
        case semAudio
    }

    /// Começa a gravar. Lança erro se o engine não iniciar.
    func iniciar() throws {
        lock.lock(); buffers.removeAll(); nivel = 0; lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        inputFormat = format

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.engineFalhou("Formato de entrada inválido (microfone indisponível?)")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Copia o buffer (o original é reutilizado pelo engine).
            guard let copia = buffer.copiaProfunda() else { return }
            let medido = copia.nivelRMS()
            self.lock.lock()
            self.buffers.append(copia)
            // Sobe rápido (acompanha o ataque da fala), desce devagar (não pisca à toa).
            self.nivel = medido > self.nivel ? medido : self.nivel * 0.82 + medido * 0.18
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFalhou(error.localizedDescription)
        }
    }

    /// Para a gravação e devolve os buffers capturados.
    func pararEColetar() throws -> (buffers: [AVAudioPCMBuffer], format: AVAudioFormat) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let coletados = buffers; nivel = 0; lock.unlock()
        guard let fmt = inputFormat, !coletados.isEmpty else {
            throw RecorderError.semAudio
        }
        return (coletados, fmt)
    }
}

extension AVAudioPCMBuffer {
    /// Intensidade da fala neste buffer, normalizada em 0…1 para desenho.
    ///
    /// Usa RMS em decibéis porque volume percebido é logarítmico: em escala linear,
    /// fala normal mal sairia do chão e a onda pareceria morta.
    func nivelRMS() -> Float {
        let frames = Int(frameLength)
        guard frames > 0, let canais = floatChannelData else { return 0 }

        var soma: Float = 0
        let amostras = canais[0]
        for i in 0..<frames {
            let v = amostras[i]
            soma += v * v
        }
        let rms = sqrt(soma / Float(frames))
        guard rms > 0 else { return 0 }

        // -50 dB (silêncio de sala) … -5 dB (fala alta) → 0…1.
        let db = 20 * log10(rms)
        return min(max((db + 50) / 45, 0), 1)
    }

    /// Cópia independente do buffer, segura para guardar fora do callback do tap.
    func copiaProfunda() -> AVAudioPCMBuffer? {
        guard let copia = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copia.frameLength = frameLength
        let canais = Int(format.channelCount)
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copia.floatChannelData {
            for c in 0..<canais {
                dst[c].update(from: src[c], count: frames)
            }
        } else if let src = int16ChannelData, let dst = copia.int16ChannelData {
            for c in 0..<canais {
                dst[c].update(from: src[c], count: frames)
            }
        } else {
            return nil
        }
        return copia
    }
}
