import Foundation

/// The login Claude Code is using: its config file's `oauthAccount` object
/// names the account, the credentials (Keychain item or `.credentials.json`)
/// hold the tokens.
public struct ClaudeLive {
    let paths: Paths
    let store: Store
    let secrets: SecretStore
    let root: URL?

    static let comma = Data(",".utf8)
    static let member = Data("\"\(ClaudeIdentity.Key.account)\":".utf8)
    static let open = Data("{".utf8)
    static let close = Data("}".utf8)

    /// `secrets` is `ClaudeSecrets.live(paths:root:)` for the live login; `root`
    /// reads a throwaway home instead of the live one.
    public init(paths: Paths, store: Store, secrets: SecretStore, root: URL? = nil) {
        self.paths = paths
        self.store = store
        self.secrets = secrets
        self.root = root
    }

    var configFile: URL { paths.claudeConfigFile(root: root) }

    /// Nil when the config or the credentials are missing.
    public func identity() throws -> Identity? {
        guard let (config, creds) = try live() else { return nil }
        return try ClaudeIdentity.fromLive(config: config, creds: creds)
    }

    /// Puts the live login under `n`: login = the credentials bytes, profile =
    /// the exact `oauthAccount` object bytes, identity read from those same
    /// bytes. `mismatch` when the live login no longer belongs to `n`.
    public func save(to n: SlotName, _ tx: Tx) throws {
        guard let (config, creds) = try live() else { throw KibaError.noLive(.claude) }
        let profile = try ClaudeIdentity.profile(config)
        var id = try ClaudeIdentity.fromOAuthAccount(profile)
        id.plan = ClaudeIdentity.planFromCreds(creds)
        guard n.belongs(to: id.email) else { throw KibaError.mismatch(.claude, n.raw) }
        try tx.put(.claude, SavedLogin(name: n, identity: id, login: creds, profile: profile, usage: nil))
    }

    /// kiba `CLAUDE-INSTALL`, in one transaction so the row read is the row
    /// installed: the row must exist (`noAccount`), its profile must name an
    /// email `n` belongs to (`mismatch`), its login must hold a `claudeAiOauth`
    /// object (`badJSON`). Then the config gets the profile, the credentials
    /// get the login, and `n` is noted as installed. A crash between the two
    /// live writes leaves the previous name installed, which `isMixed` detects.
    public func install(_ n: SlotName) throws {
        try store.write { tx in
            guard let row = try store.fetch(.claude, n) else { throw KibaError.noAccount(.claude, n.raw) }
            guard let profile = row.profile, n.belongs(to: try ClaudeIdentity.fromOAuthAccount(profile).email) else {
                throw KibaError.mismatch(.claude, n.raw)
            }
            guard try JSONDoc(row.login).objectSpan(ClaudeIdentity.Key.oauth) != nil else {
                throw KibaError.badJSON(ClaudeIdentity.Key.oauth)
            }
            let config = try spliced(profile)
            try PrivateFS.ensurePrivateDir(configFile.deletingLastPathComponent())
            try PrivateFS.writePrivate(config, to: configFile)
            try secrets.write(row.login)
            try tx.noteInstalled(.claude, n)
        }
    }

    /// kiba `CLAUDE-MIXED?`: the installed row exists, the live config names
    /// another account (email differs, or both orgs are known and differ), and
    /// the live credentials are still byte for byte that row's login.
    public func isMixed() throws -> Bool {
        guard let name = try store.installed(.claude), let row = try store.fetch(.claude, name),
              let (config, creds) = try live() else { return false }
        let id = try ClaudeIdentity.fromLive(config: config, creds: creds)
        let sameOrg = id.org.isEmpty || row.identity.org.isEmpty || id.org == row.identity.org
        guard !(name.belongs(to: id.email) && sameOrg) else { return false }
        return creds == row.login
    }

    /// The live config and credentials; nil when either is missing. The config
    /// is read first, so a missing one costs no Keychain call.
    func live() throws -> (config: Data, creds: Data)? {
        guard let config = try PrivateFS.read(configFile), let creds = try secrets.read() else { return nil }
        return (config, creds)
    }

    /// The live config with its top-level `oauthAccount` value, of any kind,
    /// replaced by `profile`; inserted before the closing brace when absent; a
    /// new document when there is no config.
    func spliced(_ profile: Data) throws -> Data {
        guard let old = try PrivateFS.read(configFile) else { return Self.open + Self.member + profile + Self.close }
        let doc = try JSONDoc(old)
        if let span = doc.valueSpan(ClaudeIdentity.Key.account) {
            return try doc.replacing(span, with: profile).data
        }
        let (brace, hasMembers) = doc.closingBrace()
        return try doc.replacing(brace ..< brace, with: (hasMembers ? Self.comma : Data()) + Self.member + profile).data
    }
}
