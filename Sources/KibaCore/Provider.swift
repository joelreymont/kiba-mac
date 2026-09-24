/// The two CLIs whose logins kiba-mac switches.
public enum Provider: String, CaseIterable, Sendable, Codable {
    case claude, codex

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The environment variable that relocates the provider's home.
    public var homeVar: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        }
    }

    /// Where the user signs in before adding an account.
    public var site: String {
        switch self {
        case .claude: return "claude.ai"
        case .codex: return "chatgpt.com"
        }
    }
}
