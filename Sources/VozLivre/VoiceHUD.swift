import AppKit

/// Pílula flutuante que aparece enquanto o app está ouvindo, com a onda da sua voz
/// reagindo ao vivo — o sinal de "estou gravando" que dá pra ver de canto de olho,
/// sem precisar caçar o ícone na barra de menu.
///
/// Fica em cima de tudo (inclusive apps em tela cheia) e nunca rouba o foco: é um
/// painel `.nonactivatingPanel` que ignora cliques, então digitar/clicar continua
/// indo pro app que você estava usando.
@MainActor
final class VoiceHUD {
    static let shared = VoiceHUD()

    private var painel: NSPanel?
    private var onda: OndaView?

    private let tamanho = NSSize(width: 168, height: 44)
    private let margemInferior: CGFloat = 96   // acima do Dock

    private init() {}

    /// Mostra a pílula ouvindo. `lendoNivel` é consultado a cada quadro.
    func mostrarOuvindo(lendoNivel: @escaping () -> Float) {
        let view = garantirPainel()
        view.entrarEmModoOuvindo(fonteDeNivel: lendoNivel)
        aparecer()
    }

    /// Troca pro estado "transcrevendo" — a onda vira um pulso neutro, sem microfone.
    func mostrarTranscrevendo() {
        // Só faz sentido se a pílula estiver de fato na tela — senão deixaria um
        // timer de animação rodando pra ninguém ver.
        guard let painel, painel.isVisible, let onda else { return }
        onda.entrarEmModoTranscrevendo()
    }

    func esconder() {
        onda?.pararAnimacao()
        guard let painel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            painel.animator().alphaValue = 0
        } completionHandler: { [weak painel] in
            painel?.orderOut(nil)
        }
    }

    // MARK: Janela

    private func garantirPainel() -> OndaView {
        if let onda { return onda }

        let painel = PainelSemFoco(contentRect: NSRect(origin: .zero, size: tamanho),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false)
        painel.isOpaque = false
        painel.backgroundColor = .clear
        painel.hasShadow = true
        // .popUpMenu mantém a pílula visível acima de apps em tela cheia (Zoom, Keynote);
        // .floating sozinho some atrás deles.
        painel.level = .popUpMenu
        painel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        painel.ignoresMouseEvents = true
        painel.isMovableByWindowBackground = false

        let view = OndaView(frame: NSRect(origin: .zero, size: tamanho))
        painel.contentView = view

        self.painel = painel
        self.onda = view
        return view
    }

    private func aparecer() {
        guard let painel else { return }
        posicionar(painel)
        painel.alphaValue = 0
        painel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            painel.animator().alphaValue = 1
        }
    }

    /// Centraliza na parte de baixo da tela onde está o mouse (a tela em que você
    /// está trabalhando, que nem sempre é a principal).
    private func posicionar(_ painel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let tela = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visivel = tela?.visibleFrame else { return }

        let x = visivel.midX - tamanho.width / 2
        let y = visivel.minY + margemInferior
        painel.setFrame(NSRect(x: x, y: y, width: tamanho.width, height: tamanho.height), display: false)
    }
}

/// Painel que nunca vira key/main — clicar ou digitar continua indo pro app de baixo.
private final class PainelSemFoco: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Desenho da onda

/// Barras de nível que rolam da direita pra esquerda, como um gravador de voz.
private final class OndaView: NSView {

    private enum Modo {
        case ouvindo
        case transcrevendo
    }

    private let quantidadeDeBarras = 14
    private let larguraDaBarra: CGFloat = 3
    private let espacoEntreBarras: CGFloat = 3.5
    private let alturaMinima: CGFloat = 3.5
    private let alturaMaxima: CGFloat = 22

    private var barras: [CGFloat]
    private var modo: Modo = .ouvindo
    private var fonteDeNivel: (() -> Float)?
    private var timer: Timer?
    private var fase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        barras = Array(repeating: 0, count: quantidadeDeBarras)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override var isFlipped: Bool { false }

    // MARK: Ciclo

    func entrarEmModoOuvindo(fonteDeNivel: @escaping () -> Float) {
        self.fonteDeNivel = fonteDeNivel
        modo = .ouvindo
        barras = Array(repeating: 0, count: quantidadeDeBarras)
        iniciarAnimacao()
    }

    func entrarEmModoTranscrevendo() {
        modo = .transcrevendo
        fonteDeNivel = nil
        iniciarAnimacao()
    }

    func pararAnimacao() {
        timer?.invalidate()
        timer = nil
    }

    private func iniciarAnimacao() {
        guard timer == nil else { return }
        // 30 fps é suficiente pra onda parecer contínua e custa quase nada de CPU.
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.avancarQuadro() }
        }
        // .common: sem isso a onda congela enquanto um menu está aberto.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func avancarQuadro() {
        switch modo {
        case .ouvindo:
            let nivel = CGFloat(fonteDeNivel?() ?? 0)
            barras.removeFirst()
            barras.append(nivel)
        case .transcrevendo:
            // Onda neutra correndo, só pra mostrar que ainda está trabalhando.
            fase += 0.25
            for i in 0..<barras.count {
                let onda = sin(fase + CGFloat(i) * 0.55)
                barras[i] = 0.18 + 0.22 * (onda + 1) / 2
            }
        }
        needsDisplay = true
    }

    // MARK: Pintura

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        desenharFundo(ctx)
        desenharIcone()
        desenharBarras(ctx)
    }

    private func desenharFundo(_ ctx: CGContext) {
        let pill = NSBezierPath(roundedRect: bounds,
                                xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.88).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        pill.lineWidth = 1
        pill.stroke()
    }

    private var corDeDestaque: NSColor {
        modo == .ouvindo ? .systemGreen : .systemGray
    }

    private func desenharIcone() {
        let nome = modo == .ouvindo ? "mic.fill" : "ellipsis"
        // Cor pela paleta do próprio símbolo. Tingir por composição (.sourceAtop)
        // pintaria também o fundo da pílula, que já está desenhado por baixo.
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [corDeDestaque]))
        guard let icone = NSImage(systemSymbolName: nome, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        let tamanho = icone.size
        let destino = NSRect(x: 16,
                             y: (bounds.height - tamanho.height) / 2,
                             width: tamanho.width,
                             height: tamanho.height)
        icone.draw(in: destino)
    }

    private func desenharBarras(_ ctx: CGContext) {
        let larguraTotal = CGFloat(quantidadeDeBarras) * larguraDaBarra
            + CGFloat(quantidadeDeBarras - 1) * espacoEntreBarras
        let inicioX = bounds.maxX - 16 - larguraTotal
        let meioY = bounds.midY

        for (i, valor) in barras.enumerated() {
            let altura = alturaMinima + (alturaMaxima - alturaMinima) * min(max(valor, 0), 1)
            let x = inicioX + CGFloat(i) * (larguraDaBarra + espacoEntreBarras)
            let rect = NSRect(x: x, y: meioY - altura / 2, width: larguraDaBarra, height: altura)

            // As barras mais novas (à direita) ficam mais acesas — dá o sentido de
            // que a onda está correndo, mesmo num quadro parado.
            let brilho = 0.45 + 0.55 * (CGFloat(i) / CGFloat(max(quantidadeDeBarras - 1, 1)))
            corDeDestaque.withAlphaComponent(brilho).setFill()
            NSBezierPath(roundedRect: rect,
                         xRadius: larguraDaBarra / 2,
                         yRadius: larguraDaBarra / 2).fill()
        }
    }
}
