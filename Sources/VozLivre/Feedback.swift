import AppKit

/// Aviso sonoro curto de começou/parou de ouvir.
///
/// No modo mãos livres (dois toques) não existe tecla segurada pra dar a sensação
/// de "está gravando" — sem um sinal, é fácil falar com o microfone desligado ou
/// deixar o app ouvindo à toa. O som resolve isso sem exigir olhar pra barra de menu.
enum Feedback {

    enum Evento {
        case comecou
        case parou

        /// Sons do próprio macOS — não precisam de arquivo no bundle.
        var nomeDoSom: String {
            switch self {
            case .comecou: return "Tink"
            case .parou:   return "Pop"
            }
        }
    }

    private static let chave = "somDeFeedback"

    /// Ligado por padrão (a chave só existe depois que o usuário mexe).
    static var ativo: Bool {
        get {
            UserDefaults.standard.object(forKey: chave) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: chave) }
    }

    @MainActor
    static func tocar(_ evento: Evento) {
        guard ativo, let som = NSSound(named: evento.nomeDoSom) else { return }
        som.volume = 0.35   // presente, mas sem assustar
        som.play()
    }
}
