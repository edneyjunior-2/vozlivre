import AppKit
import Carbon.HIToolbox

/// Janela que captura uma TECLA ÚNICA e a devolve como `Atalho`.
/// Aceita: uma tecla de função sozinha (F1–F20) OU um modificador isolado segurado (Fn, ⌥, ⌘, ⌃). Sem combinações.
///
/// Roda como janela MODAL de verdade (NSApp.runModal) — um app de barra de menu (accessory)
/// não rouba o foco do teclado de forma confiável com só `activate`/`makeKey`; sem o modal,
/// teclas digitadas aqui podiam vazar pro último app em primeiro plano (ex.: Cmd+S abrindo
/// o "Salvar" de outro app em vez de virar um atalho).
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    static let shared = ShortcutRecorder()

    private var modalAtivo = false

    private override init() { super.init() }

    func abrir(aoCapturar: @escaping (Atalho) -> Void) {
        let view = CaptureView(frame: NSRect(x: 0, y: 0, width: 420, height: 130))

        let win = NSWindow(contentRect: view.frame,
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Gravar atalho"
        win.contentView = view
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .modalPanel
        win.delegate = self

        var resultado: Atalho?
        view.onResultado = { [weak self] atalho in
            guard let atalho else {
                self?.encerrar()   // Esc — cancela na hora, sem mensagem.
                return
            }
            // Mostra a confirmação visível ANTES de fechar — sem isso, a janela
            // some instantaneamente e parece que a tecla não foi gravada.
            resultado = atalho
            view.mostrarSucesso(atalho.nome)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.encerrar()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)

        modalAtivo = true
        NSApp.runModal(for: win)

        win.delegate = nil
        win.orderOut(nil)
        if let resultado { aoCapturar(resultado) }
    }

    func windowWillClose(_ notification: Notification) {
        encerrar()
    }

    private func encerrar() {
        guard modalAtivo else { return }
        modalAtivo = false
        NSApp.stopModal()
    }
}

/// View que vira primeira-resposta e captura keyDown (tecla/função) e flagsChanged (modificador isolado).
private final class CaptureView: NSView {
    var onResultado: ((Atalho?) -> Void)?
    private let label = NSTextField(labelWithString: "")

    private var modPendente: UInt32?
    private var houveKeyDown = false

    // Detecção de duplo toque: a confirmação de "modificador segurado" espera um
    // instante pra ver se vem um segundo toque — senão o primeiro soltar já fecharia
    // a janela e o duplo toque nunca daria pra gravar aqui.
    private var confirmacaoPendente: DispatchWorkItem?
    private var ultimoToque: (codigo: UInt32, quando: Date)?
    private var estadoAnteriorTravado: Bool?
    private let janelaDuploToque: TimeInterval = 0.6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.frame = NSRect(x: 16, y: 16, width: frameRect.width - 32, height: 98)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.maximumNumberOfLines = 4
        label.stringValue = textoPadrao
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    private let textoPadrao = """
    Mãos livres: toque DUAS VEZES rápido num modificador
    (Caps Lock, ⌥, ⌘, ⌃) — liga e desliga sem segurar nada.

    Ou segure um modificador sozinho, ou aperte F1–F12. Esc cancela.
    """

    override var acceptsFirstResponder: Bool { true }

    /// Mostra a confirmação em destaque (verde) — chamado pelo ShortcutRecorder antes de fechar.
    func mostrarSucesso(_ nome: String) {
        label.textColor = .systemGreen
        label.stringValue = "✅ Atalho gravado: \(nome)"
    }

    // Tecla normal/função (ou combinação).
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onResultado?(nil)
            return
        }

        houveKeyDown = true   // bloqueia que um modificador segurado junto vire atalho isolado
        let kc = UInt32(event.keyCode)
        let mods = AtalhoUtil.carbonModifiers(de: event.modifierFlags)

        // Somente tecla única: tecla de função sozinha. Qualquer modificador junto = combinação → rejeita.
        guard KeyInfo.ehTeclaFuncao(kc), mods == 0 else {
            label.textColor = .systemRed
            label.stringValue = "⚠️ Essa tecla não vale (código \(kc)). Use UMA tecla só, sem combinação:\nsegure um modificador sozinho (Fn, ⌥, ⌘, ⌃)\nou aperte uma tecla de função (F1–F12). (Esc cancela)"
            return
        }

        let nome = AtalhoUtil.nomeLegivel(keyCode: kc, carbonMods: 0,
                                          tecla: event.charactersIgnoringModifiers)
        onResultado?(Atalho(tipo: .tecla(keyCode: kc, modifiers: 0), nome: nome))
    }

    // Modificador isolado (segurar) ou dois toques rápidos no mesmo modificador.
    override func flagsChanged(with event: NSEvent) {
        let kc = UInt32(event.keyCode)
        guard let flag = KeyInfo.flag(deModificador: kc) else {
            // Antes isso falhava em silêncio — agora pelo menos mostra o código da
            // tecla, pra dar pra diagnosticar teclados que mandam códigos incomuns
            // (comum em teclados Bluetooth de terceiros).
            label.textColor = .systemRed
            label.stringValue = "⚠️ Tecla não reconhecida (código \(kc)). Tente Caps Lock, ⌥, ⌘, ⌃, Fn ou F1–F12."
            return
        }

        let ligada = event.modifierFlags.contains(flag)

        // Caps Lock é trava: cada toque inverte a flag em vez de gerar pressiona/solta,
        // e segurá-lo não faz sentido — então ele só grava como duplo toque.
        if KeyInfo.ehTrava(kc) {
            guard estadoAnteriorTravado != ligada else { return }
            estadoAnteriorTravado = ligada
            registrarToque(kc, permiteSegurar: false)
            return
        }

        if ligada {
            registrarToque(kc, permiteSegurar: true)
        } else {
            // Soltou. Se foi o mesmo modificador e nada foi teclado, vira atalho isolado —
            // mas só depois da janela do duplo toque, pra não roubar o segundo toque.
            if let p = modPendente, p == kc, !houveKeyDown {
                agendarConfirmacaoDeSegurar(kc)
            }
            modPendente = nil
        }
    }

    /// Conta um toque e, se for o segundo do mesmo modificador dentro da janela,
    /// resolve como duplo toque.
    private func registrarToque(_ kc: UInt32, permiteSegurar: Bool) {
        confirmacaoPendente?.cancel()
        confirmacaoPendente = nil

        let agora = Date()
        if let ultimo = ultimoToque, ultimo.codigo == kc,
           agora.timeIntervalSince(ultimo.quando) <= janelaDuploToque {
            ultimoToque = nil
            modPendente = nil
            let nome = "\(AtalhoUtil.nomeModificador(kc)) 2x"
            onResultado?(Atalho(tipo: .duploToque(keyCode: kc), nome: nome))
            return
        }

        ultimoToque = (kc, agora)
        houveKeyDown = false
        modPendente = permiteSegurar ? kc : nil
        label.textColor = .labelColor
        label.stringValue = permiteSegurar
            ? "\(AtalhoUtil.nomeModificador(kc)) — toque de novo pra “2x”, ou segure e solte."
            : "\(AtalhoUtil.nomeModificador(kc)) — toque de novo pra confirmar o “2x”."
    }

    /// Confirma "modificador segurado" só se nenhum segundo toque chegar a tempo.
    private func agendarConfirmacaoDeSegurar(_ kc: UInt32) {
        let tarefa = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.confirmacaoPendente = nil
            self.ultimoToque = nil
            let nome = AtalhoUtil.nomeModificador(kc)
            self.onResultado?(Atalho(tipo: .modificador(keyCode: kc), nome: nome))
        }
        confirmacaoPendente = tarefa
        DispatchQueue.main.asyncAfter(deadline: .now() + janelaDuploToque, execute: tarefa)
    }
}

/// Conversão de modificadores AppKit→Carbon e geração de nomes legíveis.
enum AtalhoUtil {
    static func carbonModifiers(de flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    static func nomeLegivel(keyCode: UInt16, carbonMods: UInt32, tecla: String?) -> String {
        nomeLegivel(keyCode: UInt32(keyCode), carbonMods: carbonMods, tecla: tecla)
    }

    static func nomeLegivel(keyCode: UInt32, carbonMods: UInt32, tecla: String?) -> String {
        var s = ""
        if (carbonMods & UInt32(controlKey)) != 0 { s += "⌃" }
        if (carbonMods & UInt32(optionKey))  != 0 { s += "⌥" }
        if (carbonMods & UInt32(shiftKey))   != 0 { s += "⇧" }
        if (carbonMods & UInt32(cmdKey))     != 0 { s += "⌘" }
        s += nomeDaTecla(keyCode: keyCode, tecla: tecla)
        return s
    }

    /// Nome de um modificador isolado, com lado (esquerdo/direito).
    static func nomeModificador(_ kc: UInt32) -> String {
        let simbolo: String
        let lado: String
        switch Int(kc) {
        case kVK_Command:       simbolo = "⌘"; lado = " esquerdo"
        case kVK_RightCommand:  simbolo = "⌘"; lado = " direito"
        case kVK_Option:        simbolo = "⌥"; lado = " esquerdo"
        case kVK_RightOption:   simbolo = "⌥"; lado = " direito"
        case kVK_Control:       simbolo = "⌃"; lado = " esquerdo"
        case kVK_RightControl:  simbolo = "⌃"; lado = " direito"
        case kVK_Shift:         simbolo = "⇧"; lado = " esquerdo"
        case kVK_RightShift:    simbolo = "⇧"; lado = " direito"
        case kVK_Function:      simbolo = "Fn"; lado = ""
        case kVK_CapsLock:      simbolo = "Caps Lock"; lado = ""
        default:                simbolo = "Modificador"; lado = ""
        }
        return simbolo + lado
    }

    private static func nomeDaTecla(keyCode: UInt32, tecla: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space:   return "Espaço"
        case kVK_Return:  return "Return"
        case kVK_Tab:     return "Tab"
        case kVK_Delete:  return "Delete"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            if let t = tecla, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return t.uppercased()
            }
            return "Tecla\(keyCode)"
        }
    }
}
