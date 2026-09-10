import AppKit
import AVFoundation
import ApplicationServices

/// Verificação e solicitação das permissões necessárias (AC8).
enum Permissions {

    // MARK: Microfone

    static var microfoneAutorizado: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func pedirMicrofone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: Acessibilidade (necessária p/ injetar Cmd+V via CGEvent)

    static var acessibilidadeAutorizada: Bool {
        AXIsProcessTrusted()
    }

    /// Abre o prompt do sistema pedindo Acessibilidade. O usuário precisa marcar manualmente.
    @discardableResult
    static func pedirAcessibilidade() -> Bool {
        // Valor documentado de kAXTrustedCheckOptionPrompt (usado como literal para
        // evitar referência a global mutável, que o Swift 6 rejeita por concorrência).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func abrirAjustesAcessibilidade() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func abrirAjustesMicrofone() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
