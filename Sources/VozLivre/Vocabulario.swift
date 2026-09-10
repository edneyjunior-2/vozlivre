import Foundation

/// Monta o "initial prompt" que o Whisper recebe antes de transcrever.
///
/// É a alavanca mais forte pra ditado em português com termos em inglês no meio:
/// sem essa dica, o modelo aportuguesa foneticamente o que ouve — "webhook" vira
/// "e-book", "rollback" vira "um roubo aqui", "push" vira "pus".
enum Vocabulario {

    /// Frase de contexto. Fica fixa: nos testes, instrução demais compete com o
    /// vocabulário e piora o resultado — o que ajuda mesmo é a lista de termos.
    private static let cabecalho = "Ditado em português do Brasil de um desenvolvedor de software, "
        + "com pontuação. Termos de tecnologia ficam em inglês, como no original: "

    /// Termos que o Whisper mais erra em fala pt-BR misturada com inglês.
    static let termosPadrao = [
        "deploy", "build", "branch", "feature branch", "pull request", "merge",
        "commit", "push", "rollback", "hotfix", "script", "webhook", "endpoint",
        "timeout", "token", "cache", "log", "backup", "upload", "download",
        "backend", "frontend", "API", "dashboard", "layout", "template",
        "code review", "feedback", "login", "bug", "sprint", "deadline",
        "Slack", "GitHub", "Stripe", "Supabase", "Notion", "Linear", "Figma", "Jira"
    ]

    /// O Whisper aceita no máximo 224 tokens de prompt (~3,2 caracteres por token
    /// em português). Passar disso é pior que não ter prompt: ele trunca pela
    /// ESQUERDA e o corte come justamente o cabeçalho, deixando uma lista solta.
    private static let limiteDeCaracteres = 690

    private static let chave = "vocabularioDoUsuario"

    /// Termos do usuário, um por linha na janela de edição.
    static var termosDoUsuario: [String] {
        get {
            let bruto = UserDefaults.standard.string(forKey: chave) ?? ""
            return separar(bruto)
        }
        set { UserDefaults.standard.set(newValue.joined(separator: "\n"), forKey: chave) }
    }

    /// Texto cru como o usuário digitou (pra reabrir a janela de edição sem perder o formato).
    static var textoDoUsuario: String {
        get { UserDefaults.standard.string(forKey: chave) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: chave) }
    }

    /// Aceita um termo por linha ou separados por vírgula/ponto-e-vírgula.
    static func separar(_ bruto: String) -> [String] {
        bruto
            .components(separatedBy: CharacterSet(charactersIn: "\n,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Prompt final entregue ao whisper-cli.
    ///
    /// Os termos do usuário vão POR ÚLTIMO de propósito: quando a lista não cabe,
    /// o corte acontece no começo, então a posição final é a mais protegida — e
    /// também a de mais peso pro modelo.
    static func prompt() -> String {
        prompt(comTermosDoUsuario: termosDoUsuario)
    }

    /// Versão pura — a janela de edição usa isto pra prever o resultado do que está
    /// sendo digitado sem gravar nada nas preferências.
    static func prompt(comTermosDoUsuario doUsuario: [String]) -> String {
        var termos = termosPadrao + doUsuario
        // Sem duplicatas, preservando a ordem (a última ocorrência é a que vale).
        var vistos = Set<String>()
        termos = termos.reversed().filter { vistos.insert($0.lowercased()).inserted }.reversed()

        while !termos.isEmpty {
            let texto = cabecalho + termos.joined(separator: ", ") + "."
            if texto.count <= limiteDeCaracteres { return texto }
            termos.removeFirst()
        }
        return cabecalho.trimmingCharacters(in: .whitespaces)
    }
}
