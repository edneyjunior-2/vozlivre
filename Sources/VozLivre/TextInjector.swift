import AppKit

/// Injeta o texto transcrito no campo em foco (AC7).
/// Estratégia: salva o clipboard atual → coloca o texto → simula Cmd+V via CGEvent
/// → restaura o clipboard original. Normaliza em NFC para acentos do português
/// (ã, ç, é, õ) saírem corretos.
@MainActor
enum TextInjector {

    static func inserir(_ texto: String) {
        let normalizado = texto.precomposedStringWithCanonicalMapping // NFC
        guard !normalizado.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // 1. Salva o conteúdo anterior (todos os itens/tipos).
        let backup = salvarPasteboard(pasteboard)

        // 2. Coloca o texto ditado.
        pasteboard.clearContents()
        pasteboard.setString(normalizado, forType: .string)

        // 3. Simula Cmd+V.
        colarViaCmdV()

        // 4. Restaura o clipboard anterior após um pequeno delay (deixa o Cmd+V consumir).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            restaurarPasteboard(pasteboard, itens: backup)
        }
    }

    private static func colarViaCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(0x09) // tecla "V"
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Backup/restauração do pasteboard (preserva tipos não-texto, ex.: imagem)

    private static func salvarPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let itens = pb.pasteboardItems else { return [] }
        return itens.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for tipo in item.types {
                if let data = item.data(forType: tipo) {
                    dict[tipo] = data
                }
            }
            return dict
        }
    }

    private static func restaurarPasteboard(_ pb: NSPasteboard, itens: [[NSPasteboard.PasteboardType: Data]]) {
        guard !itens.isEmpty else { return }
        pb.clearContents()
        let novos: [NSPasteboardItem] = itens.map { dict in
            let item = NSPasteboardItem()
            for (tipo, data) in dict {
                item.setData(data, forType: tipo)
            }
            return item
        }
        pb.writeObjects(novos)
    }
}
