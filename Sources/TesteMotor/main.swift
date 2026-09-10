// Executável de teste: exercita a mesma API C que o WhisperMotor usa dentro do app,
// com um WAV de entrada. Serve para validar linkagem, parâmetros, VAD e prompt sem
// precisar falar no microfone.
//
// uso: TesteMotor <modelo.bin> <vad.bin> <audio.wav>

import Foundation
import AVFoundation
import CWhisper

let args = CommandLine.arguments
guard args.count == 4 else {
    print("uso: TesteMotor <modelo.bin> <vad.bin> <audio.wav>")
    exit(2)
}
let (caminhoModelo, caminhoVAD, caminhoAudio) = (args[1], args[2], args[3])

// --- lê o WAV e converte para 16 kHz mono float, como o app faz ---
func amostras(de url: URL) throws -> [Float] {
    let arquivo = try AVAudioFile(forReading: url)
    let formato = arquivo.processingFormat
    guard let entrada = AVAudioPCMBuffer(pcmFormat: formato,
                                         frameCapacity: AVAudioFrameCount(arquivo.length)) else {
        fatalError("buffer")
    }
    try arquivo.read(into: entrada)

    guard let destino = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                      channels: 1, interleaved: false),
          let conversor = AVAudioConverter(from: formato, to: destino),
          let saida = AVAudioPCMBuffer(pcmFormat: destino,
                                       frameCapacity: AVAudioFrameCount(Double(entrada.frameLength) * 16000 / formato.sampleRate) + 1024)
    else { fatalError("conversor") }

    var entregue = false
    var erro: NSError?
    _ = conversor.convert(to: saida, error: &erro) { _, status in
        if entregue { status.pointee = .endOfStream; return nil }
        entregue = true; status.pointee = .haveData; return entrada
    }
    guard let dados = saida.floatChannelData else { fatalError("saida") }
    return Array(UnsafeBufferPointer(start: dados[0], count: Int(saida.frameLength)))
}

let pcm = try amostras(de: URL(fileURLWithPath: caminhoAudio))
print("audio: \(pcm.count) amostras (\(String(format: "%.2f", Double(pcm.count)/16000))s a 16kHz)")

// --- carrega o modelo ---
var cparams = whisper_context_default_params()
cparams.use_gpu = true
cparams.flash_attn = true

var t0 = Date()
guard let ctx = whisper_init_from_file_with_params(caminhoModelo, cparams) else {
    print("ERRO: falhou ao carregar o modelo"); exit(1)
}
let tCarga = Date().timeIntervalSince(t0)
print(String(format: "carga do modelo: %.0f ms", tCarga * 1000))

// --- transcreve (mesmos parâmetros do WhisperMotor) ---
let prompt = "Ditado em português do Brasil de um desenvolvedor de software, com pontuação. "
    + "Termos de tecnologia ficam em inglês, como no original: deploy, build, branch, webhook, "
    + "endpoint, timeout, token, Stripe, Supabase, GitHub, Slack."

func transcrever(_ pcm: [Float], rotulo: String) -> (String, TimeInterval) {
    var p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
    p.print_realtime = false; p.print_progress = false
    p.print_timestamps = false; p.print_special = false
    p.translate = false; p.no_timestamps = true
    p.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

    let cIdioma = strdup("pt"), cPrompt = strdup(prompt), cVAD = strdup(caminhoVAD)
    defer { free(cIdioma); free(cPrompt); free(cVAD) }
    p.language = UnsafePointer(cIdioma)
    p.initial_prompt = UnsafePointer(cPrompt)
    p.vad = true
    p.vad_model_path = UnsafePointer(cVAD)
    var vad = whisper_vad_default_params()
    vad.speech_pad_ms = 200
    p.vad_params = vad

    let ini = Date()
    let status = pcm.withUnsafeBufferPointer { b in
        whisper_full(ctx, p, b.baseAddress, Int32(b.count))
    }
    let dur = Date().timeIntervalSince(ini)
    guard status == 0 else { return ("ERRO status \(status)", dur) }
    var texto = ""
    for i in 0..<whisper_full_n_segments(ctx) {
        if let s = whisper_full_get_segment_text(ctx, i) { texto += String(cString: s) }
    }
    return (texto.trimmingCharacters(in: .whitespacesAndNewlines), dur)
}

// primeira passada (modelo recém-carregado)
let (texto1, d1) = transcrever(pcm, rotulo: "1a")
print(String(format: "1a transcricao: %.0f ms", d1 * 1000))
print("   → \(texto1)")

// segunda passada: é o caso real do app, com o modelo JÁ residente
let (texto2, d2) = transcrever(pcm, rotulo: "2a")
print(String(format: "2a transcricao (modelo ja carregado): %.0f ms", d2 * 1000))
print("   → \(texto2)")

// silêncio: tem que voltar vazio, não frase inventada
let mudo = [Float](repeating: 0, count: 16000 * 2)
let (textoMudo, _) = transcrever(mudo, rotulo: "silencio")
print("silencio → \(textoMudo.isEmpty ? "(vazio) ✓" : "ALUCINOU: \(textoMudo)")")

whisper_free(ctx)
print(String(format: "TOTAL real por ditado com modelo residente: %.0f ms", d2 * 1000))
