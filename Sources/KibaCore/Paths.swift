import CryptoKit
import Foundation

/// Every location kiba-mac reads or writes, resolved once from the environment.
/// URLs never touch the file system: they carry no trailing slash whether or
/// not the path exists, so equal paths always compare equal.
public struct Paths: Sendable {
    /// `$HOME/Library/Application Support/Kiba`.
    public let store: URL
    /// Keychain account attribute of the live Claude credentials.
    public let username: String
    /// Keychain service of the live Claude credentials: Claude Code's for
    /// `$CLAUDE_CONFIG_DIR`.
    public let keychainService: String

    /// The service Claude Code files its credentials under.
    public static let claudeService = "Claude Code-credentials"

    /// The service every Claude Keychain item name derives from.
    private let baseService: String
    private let home: URL
    private let claudeEnv: URL?
    private let codexEnv: URL?

    /// Throws `io` when `HOME` is unset or empty, or when `HOME`,
    /// `CLAUDE_CONFIG_DIR` or `CODEX_HOME` is set to a path not starting with `/`.
    /// Tests name a throwaway base `keychainService`; the app keeps Claude Code's.
    public init(env: [String: String], username: String, keychainService base: String = Self.claudeService) throws {
        guard let home = try Self.dir(env, Var.home) else { throw KibaError.io("HOME is not set") }
        self.home = home
        self.username = username
        baseService = base
        store = Name.storeParts.reduce(home, Self.child)
        let claudeVar = try Self.value(env, Provider.claude.homeVar)
        claudeEnv = claudeVar.map(Self.url)
        keychainService = Self.service(base, dir: claudeVar)
        codexEnv = try Self.dir(env, Provider.codex.homeVar)
    }

    /// The saved-accounts database.
    public var db: URL { Self.child(store, Name.db) }
    /// Scratch space for probes and throwaway logins.
    public var probe: URL { Self.child(store, Name.probe) }

    /// Throwaway home for a provider login run by `add`.
    public func loginRoot(_ p: Provider) -> URL { Self.child(probe, Name.loginPrefix + p.rawValue) }

    /// Keychain service of the Claude login `add` runs, which exports this
    /// config dir as `CLAUDE_CONFIG_DIR`.
    public var loginService: String {
        Self.service(baseService, dir: claudeConfigDir(root: loginRoot(.claude)).path)
    }

    /// The Keychain service Claude Code (2.1.282) files credentials under
    /// when `CLAUDE_CONFIG_DIR` is `dir`: `base` alone when it is unset, else
    /// `base`, `-`, and the first hex digits of the SHA-256 of `dir` in NFC,
    /// hashed as given, trailing slash and all.
    private static func service(_ base: String, dir: String?) -> String {
        guard let dir else { return base }
        let hex = KeychainItem.hex(Data(SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))))
        return base + Name.serviceSeparator + String(decoding: hex.prefix(Name.serviceHashDigits), as: UTF8.self)
    }

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

    /// The directory an environment variable names; unset and empty both mean absent.
    private static func dir(_ env: [String: String], _ name: String) throws -> URL? {
        try value(env, name).map(url)
    }

    /// The absolute path an environment variable holds, as given; unset and
    /// empty both mean absent. `URL(filePath:)` expands a leading `~` with the
    /// process's real home and resolves other relative paths against the
    /// working directory; a value starting with `/` reaches neither, so
    /// nothing escapes `env`.
    private static func value(_ env: [String: String], _ name: String) throws -> String? {
        guard let value = env[name], !value.isEmpty else { return nil }
        guard value.utf8.first == Name.root else { throw KibaError.io("\(name) is not an absolute path: \(value)") }
        return value
    }

    private static func url(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .notDirectory)
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
        static let db = "kiba.db"
        static let probe = "probe"
        static let loginPrefix = "login-"
        static let claudeDir = ".claude"
        static let claudeConfig = ".claude.json"
        static let claudeCreds = ".credentials.json"
        static let codexDir = ".codex"
        static let codexAuth = "auth.json"
        static let serviceSeparator = "-"
        static let serviceHashDigits = 8
    }
}
