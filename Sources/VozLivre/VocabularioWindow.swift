import AppKit

/// Janela pra você listar as palavras que o app costuma errar — nomes de produto,
/// jargão do seu trabalho, termos em inglês que você fala com frequência.
///
/// Roda como modal de verdade (`NSApp.runModal`) pelo mesmo motivo do gravador de
/// atalho: um app de barra de menu não segura o foco do teclado de forma confiável,
/// e sem o modal o que você digita pode vazar pro app que estava em primeiro plano.
@MainActor
final class VocabularioWindow: NSObject, NSWindowDelegate {
    static let shared = VocabularioWindow()

    private var modalAtivo = false

    private override init() { super.init() }

    func abrir(aoSalvar: @escaping () -> Void) {
        let largura: CGFloat = 460
        let altura: CGFloat = 380

        let janela = NSWindow(contentRect: NSRect(x: 0, y: 0, width: largura, height: altura),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        janela.title = "Meu vocabulário"
        janela.center()
        janela.isReleasedWhenClosed = false
        janela.level = .modalPanel
        janela.delegate = self

        let raiz = NSView(frame: NSRect(x: 0, y: 0, width: largura, height: altura))

        let explicacao = NSTextField(wrappingLabelWithString:
            "Um termo por linha. Entram como dica pro motor de transcrição, junto com "
            + "a lista técnica que já vem no app — útil pra nomes próprios e palavras "
            + "em inglês que ele teima em aportuguesar.\n"
            + "Cabem cerca de 40 a 60 termos; o que passar disso é cortado do começo, "
            + "então deixe os mais importantes por último.")
        explicacao.frame = NSRect(x: 20, y: altura - 92, width: largura - 40, height: 74)
        explicacao.font = .systemFont(ofSize: 11)
        explicacao.textColor = .secondaryLabelColor
        raiz.addSubview(explicacao)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 58, width: largura - 40, height: altura - 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let texto = NSTextView(frame: scroll.bounds)
        texto.autoresizingMask = [.width]
        texto.isRichText = false
        texto.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        texto.string = Vocabulario.textoDoUsuario
        texto.isAutomaticQuoteSubstitutionEnabled = false
        texto.isAutomaticSpellingCorrectionEnabled = false   // não "corrigir" jargão
        scroll.documentView = texto
        raiz.addSubview(scroll)

        let contador = NSTextField(labelWithString: "")
        contador.frame = NSRect(x: 20, y: 20, width: largura - 220, height: 20)
        contador.font = .systemFont(ofSize: 11)
        contador.textColor = .secondaryLabelColor
        raiz.addSubview(contador)

        let salvar = NSButton(title: "Salvar", target: self, action: #selector(fecharModal))
        salvar.frame = NSRect(x: largura - 110, y: 14, width: 90, height: 30)
        salvar.bezelStyle = .rounded
        salvar.keyEquivalent = "\r"
        raiz.addSubview(salvar)

        let cancelar = NSButton(title: "Cancelar", target: self, action: #selector(cancelarModal))
        cancelar.frame = NSRect(x: largura - 200, y: 14, width: 90, height: 30)
        cancelar.bezelStyle = .rounded
        cancelar.keyEquivalent = "\u{1b}"
        raiz.addSubview(cancelar)

        janela.contentView = raiz

        atualizarContador(contador, texto: texto.string)
        let observador = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: texto, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.atualizarContador(contador, texto: texto.string)
                }
            }
        defer { NotificationCenter.default.removeObserver(observador) }

        cancelado = false
        NSApp.activate(ignoringOtherApps: true)
        janela.makeKeyAndOrderFront(nil)
        janela.makeFirstResponder(texto)

        modalAtivo = true
        NSApp.runModal(for: janela)

        janela.delegate = nil
        janela.orderOut(nil)

        guard !cancelado else { return }
        Vocabulario.textoDoUsuario = texto.string
        aoSalvar()
    }

    private var cancelado = false

    /// Mostra quantos termos entraram e avisa se o prompt está estourando o limite.
    private func atualizarContador(_ campo: NSTextField, texto: String) {
        let termos = Vocabulario.separar(texto)
        // Cabe se nenhum termo do usuário ficou de fora do corte (os padrões são
        // sacrificados primeiro, de propósito).
        let resultado = Vocabulario.prompt(comTermosDoUsuario: termos)
        let cabe = termos.allSatisfy { resultado.contains($0) }

        if termos.isEmpty {
            campo.stringValue = "Nenhum termo — usando só a lista padrão."
            campo.textColor = .secondaryLabelColor
        } else if cabe {
            campo.stringValue = "\(termos.count) termo\(termos.count == 1 ? "" : "s")."
            campo.textColor = .secondaryLabelColor
        } else {
            campo.stringValue = "\(termos.count) termos — passou do limite, os primeiros serão cortados."
            campo.textColor = .systemOrange
        }
    }

    @objc private func fecharModal() { encerrar() }

    @objc private func cancelarModal() {
        cancelado = true
        encerrar()
    }

    func windowWillClose(_ notification: Notification) { encerrar() }

    private func encerrar() {
        guard modalAtivo else { return }
        modalAtivo = false
        NSApp.stopModal()
    }
}
