import AppKit

// VozLivre — app de ditado por voz, 100% local, para macOS 26 (Apple Silicon).
// Bootstrap: sobe como app de barra de menu (accessory), sem janela principal.

// Instância única: se já houver outro VozLivre rodando, encerra este antes de montar a UI
// (evita dois ícones na barra de menu e conflito no registro do atalho).
if let bundleID = Bundle.main.bundleIdentifier {
    let meuPID = ProcessInfo.processInfo.processIdentifier
    let jaRodando = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != meuPID }
    if jaRodando {
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // sem ícone no Dock / sem janela = item de barra de menu
app.run()
