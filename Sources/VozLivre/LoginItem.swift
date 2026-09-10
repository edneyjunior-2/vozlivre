import ServiceManagement

/// Controla o "abrir junto com o Mac" via SMAppService (login item, macOS 13+).
enum LoginItem {

    enum LoginError: Error, CustomStringConvertible {
        case requerAprovacao
        var description: String {
            "Ative o VozLivre em Ajustes do Sistema › Geral › Itens de Início."
        }
    }

    /// Está configurado para abrir no login?
    static var ativo: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Liga ou desliga o início automático. Lança erro em falha (tratado pela UI).
    static func definir(_ ligar: Bool) throws {
        if ligar {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            // Pós-registro o macOS pode exigir aprovação manual do usuário.
            if SMAppService.mainApp.status == .requiresApproval {
                throw LoginError.requerAprovacao
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
