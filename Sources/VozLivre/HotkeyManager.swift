import AppKit
import Carbon.HIToolbox

/// Modos de ativação (AC6 da v1), persistidos em UserDefaults.
enum ModoAtivacao: String {
    case pushToTalk   // segura pra falar, solta pra transcrever
    case toggle       // aperta liga, aperta desliga

    var descricao: String {
        switch self {
        case .pushToTalk: return "Segurar pra falar (push-to-talk)"
        case .toggle:     return "Apertar liga/desliga (toggle)"
        }
    }
}

/// Tipo de atalho: tecla normal/função, modificador isolado segurado, ou dois toques
/// rápidos num modificador (mãos livres — não precisa segurar nada).
enum TipoAtalho: Equatable {
    case tecla(keyCode: UInt32, modifiers: UInt32)
    case modificador(keyCode: UInt32)   // ex.: ⌥ direito segurado
    case duploToque(keyCode: UInt32)    // ex.: Caps Lock apertado 2x rápido
}

/// Definição de um atalho persistível.
struct Atalho: Equatable {
    var tipo: TipoAtalho
    var nome: String

    /// Duplo toque é sempre liga/desliga — não existe "segurar" nesse modo.
    var forcaToggle: Bool {
        if case .duploToque = tipo { return true }
        return false
    }
}

/// Registra o atalho global e dispara callbacks de pressionar/soltar (AC5).
/// - Tecla/função: Carbon RegisterEventHotKey (entrega pressed E released → push-to-talk).
/// - Modificador isolado: monitor de flagsChanged (NSEvent global + local).
/// - Duplo toque: mesmo monitor, contando dois toques dentro de uma janela curta.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    /// Dois toques rápidos no modificador configurado — alterna gravar/parar.
    var onToqueDuplo: (() -> Void)?
    /// Diagnóstico: dispara pra QUALQUER modificador reconhecido, mesmo que não seja
    /// o atalho configurado — usado pra descobrir o que um teclado (ex.: Bluetooth)
    /// está realmente mandando.
    var onEventoQualquerModificador: ((UInt32, Bool) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var monitorGlobal: Any?
    private var monitorLocal: Any?
    private let signature: OSType = 0x565A4C56 // 'VZLV'

    // Debounce do modificador isolado: alguns teclados Bluetooth mandam um solavanco
    // (solta-e-aperta em milissegundos) em vez de uma pressão contínua estável. Sem
    // isso, cada solavanco vira um toque completo (ativa e desativa sozinho).
    private var tarefaSoltarPendente: DispatchWorkItem?
    private let janelaDebounce: TimeInterval = 0.15

    // Estado da detecção de duplo toque.
    private var ultimoToque: Date?
    private var estadoAnteriorTravado: Bool?

    private init() {}

    /// (Re)registra o atalho. Devolve false só no caso Carbon falhar (ex.: já usado pelo sistema).
    @discardableResult
    func registrar(_ atalho: Atalho) -> Bool {
        desregistrar()
        switch atalho.tipo {
        case .tecla(let keyCode, let modifiers):
            return registrarTecla(keyCode: keyCode, modifiers: modifiers)
        case .modificador(let keyCode):
            registrarModificador(keyCode: keyCode)
            return true
        case .duploToque(let keyCode):
            registrarDuploToque(keyCode: keyCode)
            return true
        }
    }

    func desregistrar() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
        if let m = monitorGlobal { NSEvent.removeMonitor(m); monitorGlobal = nil }
        if let m = monitorLocal { NSEvent.removeMonitor(m); monitorLocal = nil }
        tarefaSoltarPendente?.cancel()
        tarefaSoltarPendente = nil
        ultimoToque = nil
        estadoAnteriorTravado = nil
    }

    // MARK: Tecla / função (Carbon)

    private func registrarTecla(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let callback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return noErr }
            let kind = GetEventKind(eventRef)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if kind == UInt32(kEventHotKeyPressed) {
                        HotkeyManager.shared.onPressed?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        HotkeyManager.shared.onReleased?()
                    }
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 2, &eventSpecs, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    // MARK: Monitores de flagsChanged

    /// Instala os monitores global + local de `flagsChanged` com o mesmo tratador.
    /// O local é necessário porque o global não recebe eventos quando o próprio
    /// VozLivre está em primeiro plano (ex.: janela de gravar atalho aberta).
    private func instalarMonitores(_ handler: @escaping (NSEvent) -> Void) {
        monitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { handler(event) }
        }
        monitorLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { handler(event) }
            return event
        }
    }

    /// Diagnóstico comum aos dois modos baseados em flagsChanged.
    private func reportarDiagnostico(_ event: NSEvent) {
        let kc = UInt32(event.keyCode)
        if let flagQualquer = KeyInfo.flag(deModificador: kc) {
            onEventoQualquerModificador?(kc, event.modifierFlags.contains(flagQualquer))
        }
    }

    // MARK: Modificador isolado (segurar)

    private func registrarModificador(keyCode alvo: UInt32) {
        guard let flag = KeyInfo.flag(deModificador: alvo) else { return }

        instalarMonitores { [weak self] event in
            guard let self else { return }
            self.reportarDiagnostico(event)
            guard UInt32(event.keyCode) == alvo else { return }

            // Sem trava de estado aqui de propósito — onPressed/onReleased já são
            // idempotentes do lado do DictationController (guard !gravando / guard
            // gravando), então é seguro disparar de novo sem risco de ficar "preso".
            if event.modifierFlags.contains(flag) {
                // Pressionou — cancela qualquer "soltar" pendente (era só solavanco).
                self.tarefaSoltarPendente?.cancel()
                self.tarefaSoltarPendente = nil
                self.onPressed?()
            } else {
                // Soltou — não confirma na hora; espera a janela de debounce pra ver
                // se não é um solavanco (solta-e-aperta rápido demais pra ser real).
                let tarefa = DispatchWorkItem { [weak self] in self?.onReleased?() }
                self.tarefaSoltarPendente = tarefa
                DispatchQueue.main.asyncAfter(deadline: .now() + self.janelaDebounce, execute: tarefa)
            }
        }
    }

    // MARK: Duplo toque (mãos livres)

    /// Dois toques rápidos no modificador alternam gravar/parar. Nada fica segurado.
    ///
    /// Caps Lock é diferente das outras modificadoras: ele é uma trava, então cada
    /// toque INVERTE o estado da flag (liga, depois desliga) em vez de gerar um par
    /// pressiona/solta. Por isso, nele contamos toda mudança real de estado como um
    /// toque; nas demais, contamos só a pressão. Efeito colateral bem-vindo: como
    /// dois toques são duas inversões, o Caps Lock volta exatamente como estava.
    private func registrarDuploToque(keyCode alvo: UInt32) {
        guard let flag = KeyInfo.flag(deModificador: alvo) else { return }
        let ehTrava = KeyInfo.ehTrava(alvo)
        // Caps Lock tem um atraso próprio no macOS (evita acionamento acidental), o
        // que espaça naturalmente os dois toques — por isso a janela maior nele.
        let janela: TimeInterval = ehTrava ? 0.6 : 0.4

        instalarMonitores { [weak self] event in
            guard let self else { return }
            self.reportarDiagnostico(event)
            guard UInt32(event.keyCode) == alvo else { return }

            let ligada = event.modifierFlags.contains(flag)

            if ehTrava {
                // Ignora eventos que não mudam o estado da trava (o soltar da tecla
                // repete a mesma flag e viraria um toque fantasma).
                guard self.estadoAnteriorTravado != ligada else { return }
                self.estadoAnteriorTravado = ligada
            } else {
                guard ligada else { return }   // só a pressão conta
            }

            let agora = Date()
            if let ultimo = self.ultimoToque, agora.timeIntervalSince(ultimo) <= janela {
                self.ultimoToque = nil
                self.onToqueDuplo?()
            } else {
                self.ultimoToque = agora
            }
        }
    }
}

/// Utilitários de mapeamento de teclas modificadoras.
enum KeyInfo {
    /// Mapeia o keyCode de uma tecla modificadora para a flag de NSEvent correspondente.
    static func flag(deModificador kc: UInt32) -> NSEvent.ModifierFlags? {
        switch Int(kc) {
        case kVK_Command, kVK_RightCommand:   return .command
        case kVK_Option, kVK_RightOption:     return .option
        case kVK_Control, kVK_RightControl:   return .control
        case kVK_Shift, kVK_RightShift:       return .shift
        case kVK_Function:                    return .function
        case kVK_CapsLock:                    return .capsLock
        default:                              return nil
        }
    }

    /// Modificadoras que travam (o estado fica ligado depois do toque) em vez de
    /// gerarem um par pressiona/solta.
    static func ehTrava(_ kc: UInt32) -> Bool {
        Int(kc) == kVK_CapsLock
    }

    static func ehModificador(_ kc: UInt32) -> Bool {
        flag(deModificador: kc) != nil
    }

    static func ehTeclaFuncao(_ kc: UInt32) -> Bool {
        let funcoes: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        return funcoes.contains(Int(kc))
    }
}

/// Atalhos pré-definidos — somente tecla única.
enum AtalhosPreset {
    static let capsLockDuplo = Atalho(
        tipo: .duploToque(keyCode: UInt32(kVK_CapsLock)),
        nome: "Caps Lock 2x")
    static let optDireitoDuplo = Atalho(
        tipo: .duploToque(keyCode: UInt32(kVK_RightOption)),
        nome: "⌥ direito 2x")
    static let cmdDireitoDuplo = Atalho(
        tipo: .duploToque(keyCode: UInt32(kVK_RightCommand)),
        nome: "⌘ direito 2x")
    static let fn = Atalho(
        tipo: .modificador(keyCode: UInt32(kVK_Function)),
        nome: "Fn")
    static let optDireito = Atalho(
        tipo: .modificador(keyCode: UInt32(kVK_RightOption)),
        nome: "⌥ direito")
    static let cmdDireito = Atalho(
        tipo: .modificador(keyCode: UInt32(kVK_RightCommand)),
        nome: "⌘ direito")
    static let f5 = Atalho(
        tipo: .tecla(keyCode: UInt32(kVK_F5), modifiers: 0),
        nome: "F5")

    /// Mãos livres primeiro (dois toques), depois os de segurar.
    static let todos = [capsLockDuplo, optDireitoDuplo, cmdDireitoDuplo, fn, optDireito, cmdDireito, f5]
    static let padrao = capsLockDuplo
}
