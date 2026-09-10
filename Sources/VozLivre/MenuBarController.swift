import AppKit

/// Estados visuais do app, refletidos no ícone da barra de menu (AC2).
enum AppState {
    case ocioso
    case gravando
    case transcrevendo

    var symbolName: String {
        switch self {
        case .ocioso:        return "mic"
        case .gravando:      return "mic.fill"
        case .transcrevendo: return "ellipsis"
        }
    }

    var descricao: String {
        switch self {
        case .ocioso:        return "Pronto"
        case .gravando:      return "Gravando…"
        case .transcrevendo: return "Transcrevendo…"
        }
    }
}

/// Monta o item na barra de menu, reflete o estado e liga tudo (hotkey + ditado).
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let dictation = DictationController()

    private var atalhoAtual: Atalho = AtalhosPreset.padrao
    private var ultimaMensagem = "Pronto"
    private var timerPisca: Timer?

    /// Mostra no menu cada tecla modificadora detectada — só pra depurar teclado.
    private var diagnosticoLigado: Bool {
        get { UserDefaults.standard.bool(forKey: "diagnosticoTeclas") }
        set { UserDefaults.standard.set(newValue, forKey: "diagnosticoTeclas") }
    }

    private(set) var state: AppState = .ocioso {
        didSet { atualizarIcone() }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        carregarPreferencias()
        atualizarIcone()
        configurarInicioAutomatico()
        montarMenu()
        configurarDitado()
        configurarHotkey()
        pedirPermissoesIniciais()

        // Prepara o motor logo na abertura. A PRIMEIRA carga de cada execução paga a
        // compilação dos shaders da GPU (~7s); pagá-la aqui, em segundo plano, evita
        // que ela caia justamente no primeiro ditado do usuário. Depois disso, o
        // modelo é solto por ociosidade e as recargas custam ~0,4s.
        WhisperMotor.shared.preaquecer()
    }

    // MARK: Setup

    private func carregarPreferencias() {
        let d = UserDefaults.standard

        // Migração única para o modo mãos livres. Quem já usava o app tinha um atalho
        // de "segurar" salvo, e sem isso a nova experiência não chegaria nele. Roda
        // uma vez só — depois disso a escolha do menu manda.
        if !d.bool(forKey: "migrouMaosLivres") {
            d.set(true, forKey: "migrouMaosLivres")
            atalhoAtual = AtalhosPreset.padrao
            persistirAtalho(atalhoAtual)
            return
        }

        guard let tipoStr = d.string(forKey: "atalhoTipo") else { return }
        let keyCode = UInt32(d.integer(forKey: "atalhoKeyCode"))
        let nome = d.string(forKey: "atalhoNome") ?? "Atalho"
        switch tipoStr {
        case "duploToque":
            atalhoAtual = Atalho(tipo: .duploToque(keyCode: keyCode), nome: nome)
        case "modificador":
            atalhoAtual = Atalho(tipo: .modificador(keyCode: keyCode), nome: nome)
        default:
            let mods = UInt32(d.integer(forKey: "atalhoModifiers"))
            // Somente tecla única: ignora combinações salvas por versões antigas (mantém o padrão).
            if mods == 0 {
                atalhoAtual = Atalho(tipo: .tecla(keyCode: keyCode, modifiers: 0), nome: nome)
            }
        }
    }

    /// Grava o atalho nas preferências, sem registrar nem mexer na UI.
    private func persistirAtalho(_ atalho: Atalho) {
        let d = UserDefaults.standard
        switch atalho.tipo {
        case .tecla(let keyCode, let modifiers):
            d.set("tecla", forKey: "atalhoTipo")
            d.set(Int(keyCode), forKey: "atalhoKeyCode")
            d.set(Int(modifiers), forKey: "atalhoModifiers")
        case .modificador(let keyCode):
            d.set("modificador", forKey: "atalhoTipo")
            d.set(Int(keyCode), forKey: "atalhoKeyCode")
        case .duploToque(let keyCode):
            d.set("duploToque", forKey: "atalhoTipo")
            d.set(Int(keyCode), forKey: "atalhoKeyCode")
        }
        d.set(atalho.nome, forKey: "atalhoNome")
    }

    /// Aplica e persiste um atalho (vindo de preset ou do gravador), registrando-o de imediato.
    private func aplicarAtalho(_ atalho: Atalho) {
        atalhoAtual = atalho
        persistirAtalho(atalho)
        if HotkeyManager.shared.registrar(atalho) {
            ultimaMensagem = "Atalho definido: \(atalho.nome)"
        } else {
            ultimaMensagem = "Atalho \(atalho.nome) em uso pelo sistema — escolha outro."
        }
        montarMenu()
    }

    private func configurarDitado() {
        dictation.onEstado = { [weak self] estado in
            self?.state = estado
            self?.montarMenu()
        }
        dictation.onMensagem = { [weak self] msg in
            self?.ultimaMensagem = msg
            self?.montarMenu()
        }
    }

    private func configurarHotkey() {
        HotkeyManager.shared.onPressed = { [weak self] in self?.dictation.atalhoPressionado() }
        HotkeyManager.shared.onReleased = { [weak self] in self?.dictation.atalhoSolto() }
        HotkeyManager.shared.onToqueDuplo = { [weak self] in self?.dictation.alternarGravacao() }
        // Diagnóstico: mostra no menu qualquer tecla modificadora detectada globalmente,
        // mesmo que não seja a configurada — ajuda a identificar o que um teclado incomum
        // (ex.: Bluetooth) está realmente enviando. Desligado por padrão, senão cada toque
        // apaga a mensagem útil ("Inserido: …").
        HotkeyManager.shared.onEventoQualquerModificador = { [weak self] codigo, pressionado in
            guard let self, self.diagnosticoLigado else { return }
            self.ultimaMensagem = "Detectado: código \(codigo) — \(pressionado ? "pressionado" : "solto")"
            self.montarMenu()
        }
        if !HotkeyManager.shared.registrar(atalhoAtual) {
            ultimaMensagem = "Atalho \(atalhoAtual.nome) em uso pelo sistema — escolha outro."
            montarMenu()
        }
    }

    private func pedirPermissoesIniciais() {
        Task { _ = await Permissions.pedirMicrofone() }
        if !Permissions.acessibilidadeAutorizada {
            Permissions.pedirAcessibilidade()
        }
    }

    /// Na primeira execução, liga o "abrir junto com o Mac" (uma vez só).
    private func configurarInicioAutomatico() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "loginConfigurado") else { return }
        d.set(true, forKey: "loginConfigurado")
        do {
            try LoginItem.definir(true)
        } catch {
            ultimaMensagem = "Início automático: \(error)"
        }
    }

    // MARK: Ícone

    private func atualizarIcone() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: state.symbolName,
                               accessibilityDescription: state.descricao)
        button.toolTip = "VozLivre — \(state.descricao)"
        atualizarPisca(button)
    }

    /// Pisca o ícone enquanto está ouvindo. No modo mãos livres nada fica segurado,
    /// então o ícone é a única confirmação contínua de que o microfone está aberto.
    private func atualizarPisca(_ button: NSStatusBarButton) {
        timerPisca?.invalidate()
        timerPisca = nil
        button.alphaValue = 1.0

        guard case .gravando = state else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            MainActor.assumeIsolated {
                button.alphaValue = button.alphaValue > 0.6 ? 0.3 : 1.0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timerPisca = timer
    }

    // MARK: Menu

    private func montarMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "VozLivre — \(state.descricao)", action: nil, keyEquivalent: ""))
        let msgItem = NSMenuItem(title: ultimaMensagem, action: nil, keyEquivalent: "")
        msgItem.isEnabled = false
        menu.addItem(msgItem)
        menu.addItem(.separator())

        // Modo de ativação — irrelevante quando o gatilho são dois toques.
        if atalhoAtual.forcaToggle {
            let item = NSMenuItem(title: "Modo: mãos livres (2 toques ligam, 2 toques escrevem)",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let modoMenu = NSMenu()
            for m in [ModoAtivacao.pushToTalk, .toggle] {
                let item = NSMenuItem(title: m.descricao, action: #selector(selecionarModo(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m.rawValue
                item.state = (dictation.modo == m) ? .on : .off
                modoMenu.addItem(item)
            }
            let modoRoot = NSMenuItem(title: "Modo de ativação", action: nil, keyEquivalent: "")
            modoRoot.submenu = modoMenu
            menu.addItem(modoRoot)
        }

        // Atalho
        let atalhoMenu = NSMenu()
        for preset in AtalhosPreset.todos {
            let item = NSMenuItem(title: preset.nome, action: #selector(selecionarAtalho(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.nome
            item.state = (atalhoAtual.nome == preset.nome) ? .on : .off
            atalhoMenu.addItem(item)
        }
        let atalhoRoot = NSMenuItem(title: "Atalho (\(atalhoAtual.nome))", action: nil, keyEquivalent: "")
        atalhoRoot.submenu = atalhoMenu
        menu.addItem(atalhoRoot)

        let gravarItem = NSMenuItem(title: "Gravar novo atalho…", action: #selector(gravarNovoAtalho), keyEquivalent: "")
        gravarItem.target = self
        menu.addItem(gravarItem)

        let vocabItem = NSMenuItem(title: "Meu vocabulário…", action: #selector(editarVocabulario), keyEquivalent: "")
        vocabItem.target = self
        menu.addItem(vocabItem)

        menu.addItem(.separator())

        // Permissões
        let micOK = Permissions.microfoneAutorizado
        let micItem = NSMenuItem(title: micOK ? "✓ Microfone autorizado" : "⚠️ Autorizar microfone…",
                                 action: micOK ? nil : #selector(abrirMicrofone), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)

        let axOK = Permissions.acessibilidadeAutorizada
        let axItem = NSMenuItem(title: axOK ? "✓ Acessibilidade autorizada" : "⚠️ Autorizar acessibilidade…",
                                action: axOK ? nil : #selector(abrirAcessibilidade), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)

        menu.addItem(.separator())
        let hudToggle = NSMenuItem(title: "Mostrar onda de voz na tela", action: #selector(alternarHUD), keyEquivalent: "")
        hudToggle.target = self
        hudToggle.state = HUDPreferencia.ativo ? .on : .off
        menu.addItem(hudToggle)

        let somToggle = NSMenuItem(title: "Aviso sonoro ao ouvir/parar", action: #selector(alternarSom), keyEquivalent: "")
        somToggle.target = self
        somToggle.state = Feedback.ativo ? .on : .off
        menu.addItem(somToggle)

        let diagToggle = NSMenuItem(title: "Diagnóstico de teclas", action: #selector(alternarDiagnostico), keyEquivalent: "")
        diagToggle.target = self
        diagToggle.state = diagnosticoLigado ? .on : .off
        menu.addItem(diagToggle)

        menu.addItem(.separator())
        let loginToggle = NSMenuItem(title: "Abrir junto com o Mac", action: #selector(alternarLogin), keyEquivalent: "")
        loginToggle.target = self
        loginToggle.state = LoginItem.ativo ? .on : .off
        menu.addItem(loginToggle)

        menu.addItem(.separator())
        let sair = NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(sair)

        statusItem.menu = menu
    }

    // MARK: Ações

    @objc private func selecionarModo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = ModoAtivacao(rawValue: raw) else { return }
        dictation.modo = m
        montarMenu()
    }

    @objc private func selecionarAtalho(_ sender: NSMenuItem) {
        guard let nome = sender.representedObject as? String,
              let preset = AtalhosPreset.todos.first(where: { $0.nome == nome }) else { return }
        aplicarAtalho(preset)
    }

    @objc private func gravarNovoAtalho() {
        ShortcutRecorder.shared.abrir { [weak self] atalho in
            self?.aplicarAtalho(atalho)
        }
    }

    @objc private func editarVocabulario() {
        VocabularioWindow.shared.abrir { [weak self] in
            let quantos = Vocabulario.termosDoUsuario.count
            self?.ultimaMensagem = quantos == 0
                ? "Vocabulário limpo — usando a lista padrão."
                : "Vocabulário salvo: \(quantos) termo\(quantos == 1 ? "" : "s")."
            self?.montarMenu()
        }
    }

    @objc private func alternarHUD() {
        HUDPreferencia.ativo.toggle()
        if !HUDPreferencia.ativo { VoiceHUD.shared.esconder() }
        ultimaMensagem = HUDPreferencia.ativo ? "Onda de voz ligada." : "Onda de voz desligada."
        montarMenu()
    }

    @objc private func alternarSom() {
        Feedback.ativo.toggle()
        ultimaMensagem = Feedback.ativo ? "Aviso sonoro ligado." : "Aviso sonoro desligado."
        montarMenu()
    }

    @objc private func alternarDiagnostico() {
        diagnosticoLigado.toggle()
        ultimaMensagem = diagnosticoLigado ? "Diagnóstico ligado — aperte uma tecla." : "Pronto"
        montarMenu()
    }

    @objc private func abrirMicrofone() { Permissions.abrirAjustesMicrofone() }
    @objc private func abrirAcessibilidade() { Permissions.abrirAjustesAcessibilidade() }

    @objc private func alternarLogin() {
        do {
            try LoginItem.definir(!LoginItem.ativo)
            ultimaMensagem = LoginItem.ativo ? "Vai abrir junto com o Mac." : "Não abre mais no login."
        } catch {
            ultimaMensagem = "\(error)"
        }
        montarMenu()
    }
}
