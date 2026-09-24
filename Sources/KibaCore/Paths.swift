import Foundation

/// Every location kiba-mac reads or writes, resolved once from the environment.
/// URLs never touch the file system: they carry no trailing slash whether or
/// not the path exists, so equal paths always compare equal.
public struct Paths: Sendable {
    /// `$HOME/Library/Application Support/Kiba`.
    public let store: URL
    /// Keychain account attribute of the live Claude credentials.
    public let username: String
    /// Keychain service of the live Claude credentials.
    public let keychainService = "Claude Code-credentials"

    private let home: URL
    private let claudeEnv: URL?
    private let codexEnv: URL?

    /// Throws `io` when `HOME` is unset or empty, or when `HOME`,
    /// `CLAUDE_CONFIG_DIR` or `CODEX_HOME` is set to a path not starting with `/`.
    public init(env: [String: String], username: String) throws {
        guard let home = try Self.dir(env, Var.home) else { throw KibaError.io("HOME is not set") }
        self.home = home
        self.username = username
        store = Name.storeParts.reduce(home, Self.child)
        claudeEnv = try Self.dir(env, Provider.claude.homeVar)
        codexEnv = try Self.dir(env, Provider.codex.homeVar)
    }

    /// Store mutex directory.
    public var lock: URL { Self.child(store, Name.lock) }
    /// Scratch space for probes and throwaway logins.
    public var probe: URL { Self.child(store, Name.probe) }

    public func providerDir(_ p: Provider) -> URL { Self.child(store, p.rawValue) }
    public func slotDir(_ p: Provider, _ n: SlotName) -> URL { Self.child(providerDir(p), n.raw) }
    public func slotFile(_ p: Provider, _ n: SlotName, _ file: String) -> URL { Self.child(slotDir(p, n), file) }
    public func usageFile(_ p: Provider, _ n: SlotName) -> URL { slotFile(p, n, Name.usage) }
    /// Names the slot whose files are live.
    public func installedFile(_ p: Provider) -> URL { Self.child(providerDir(p), Name.installed) }
    /// Present while a two-file install is in flight.
    public func markFile(_ p: Provider) -> URL { Self.child(providerDir(p), Name.installing) }
    /// Throwaway home for a provider login run by `add`.
    public func loginRoot(_ p: Provider) -> URL { Self.child(probe, Name.loginPrefix + p.rawValue) }

    /// `root/.claude`, else `$CLAUDE_CONFIG_DIR`, else `$HOME/.claude`.
    public func claudeConfigDir(root: URL?) -> URL {
        claudeExplicit(root: root) ?? Self.child(home, Name.claudeDir)
    }

    /// Inside an explicit config dir (a root or `$CLAUDE_CONFIG_DIR`); else `$HOME/.claude.json`.
    public func claudeConfigFile(root: URL?) -> URL {
        Self.child(claudeExplicit(root: root) ?? home, Name.claudeConfig)
    }

    public func claudeCredsFile(root: URL?) -> URL {
        Self.child(claudeConfigDir(root: root), Name.claudeCreds)
    }

    /// `root/.codex`, else `$CODEX_HOME`, else `$HOME/.codex`.
    public func codexHome(root: URL?) -> URL {
        root.map { Self.child($0, Name.codexDir) } ?? codexEnv ?? Self.child(home, Name.codexDir)
    }

    public func codexAuthFile(root: URL?) -> URL {
        Self.child(codexHome(root: root), Name.codexAuth)
    }

    /// The Claude config dir when a root or `$CLAUDE_CONFIG_DIR` names it.
    private func claudeExplicit(root: URL?) -> URL? {
        root.map { Self.child($0, Name.claudeDir) } ?? claudeEnv
    }

    /// The directory an environment variable names; unset and empty both mean
    /// absent. `URL(filePath:)` expands a leading `~` with the process's real
    /// home and resolves other relative paths against the working directory;
    /// a value starting with `/` reaches neither, so nothing escapes `env`.
    private static func dir(_ env: [String: String], _ name: String) throws -> URL? {
        guard let value = env[name], !value.isEmpty else { return nil }
        guard value.utf8.first == Name.root else { throw KibaError.io("\(name) is not an absolute path: \(value)") }
        return URL(filePath: value, directoryHint: .notDirectory)
    }

    private static func child(_ url: URL, _ name: String) -> URL {
        url.appending(component: name, directoryHint: .notDirectory)
    }

    private enum Var {
        static let home = "HOME"
    }

    private enum Name {
        static let root = UInt8(ascii: "/")
        static let storeParts = ["Library", "Application Support", "Kiba"]
        static let lock = "lock"
        static let probe = "probe"
        static let usage = "usage.json"
        static let installed = ".installed"
        static let installing = ".installing"
        static let loginPrefix = "login-"
        static let claudeDir = ".claude"
        static let claudeConfig = ".claude.json"
        static let claudeCreds = ".credentials.json"
        static let codexDir = ".codex"
        static let codexAuth = "auth.json"
    }
}
