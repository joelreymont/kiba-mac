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

    /// Nil when there are no credentials; `orphanLive` when they exist
    /// without a config naming their account.
    public func identity() throws -> Identity? {
        try login()?.identity
    }

    /// The login as one read, decoded; nil as `identity`.
    func login() throws -> LoginRead? {
        guard let (config, creds) = try live() else { return nil }
        return try Self.decode(config, creds)
    }

    /// The login a config and credentials hold: login = the credentials
    /// bytes, profile = the exact `oauthAccount` object bytes, identity
    /// decoded from those same bytes plus the credentials' plan. Only that
    /// object is decoded: the rest of `.claude.json` is Claude Code's.
    static func decode(_ config: Data, _ creds: Data) throws -> LoginRead {
        let profile = try ClaudeIdentity.profile(config)
        var id = try ClaudeIdentity.fromOAuthAccount(profile)
        id.plan = ClaudeIdentity.planFromCreds(creds)
        return LoginRead(identity: id, login: creds, profile: profile)
    }

    /// kiba `CLAUDE-INSTALL`. The row must exist (`noAccount`), its profile
    /// must name an email `n` belongs to (`mismatch`), its login must hold a
    /// `claudeAiOauth` object (`badJSON`); then `n` is noted as pending under
    /// a new claim and committed, so a crash between the two live writes
    /// leaves a pending install, which `isMixed` reports. A second
    /// transaction first checks the marker is still this install's
    /// (`superseded`, nothing written, when another install has noted its
    /// own since), then gives the config the profile and the credentials the
    /// login, notes `n` as installed at `at` (epoch seconds) and clears its
    /// own marker. When a live write fails, the previous config goes back and
    /// the write's error is thrown; the marker stays unless the live files
    /// are known to be the pair from before, which no install had left
    /// pending.
    public func install(_ n: SlotName, at: Int) throws {
        let (change, claim) = try store.write { tx in
            let change = try prepare(n)
            let claim = try tx.notePending(.claude, n)
            return (change, claim)
        }
        let failure = try store.write { tx -> (any Error)? in
            guard try tx.owns(.claude, claim) else { throw KibaError.superseded }
            do {
                try putConfig(change.after)
                try secrets.write(change.login)
            } catch {
                if restored(change) { try tx.clearPending(.claude, claim) }
                return error
            }
            try tx.noteInstalled(.claude, n, at: at)
            try tx.clearPending(.claude, claim)
            return nil
        }
        if let failure { throw failure }
    }

    /// After a failed live write: puts the previous config back, then says
    /// whether the live files are known to be the pair from before the
    /// install and no install was pending then. The credentials are read
    /// back: a write that failed may still have replaced them. A config that
    /// cannot go back, or credentials that cannot be read, leave it unknown.
    func restored(_ c: Change) -> Bool {
        guard (try? putConfig(c.config)) != nil, c.settled else { return false }
        do {
            return try secrets.read() == c.creds
        } catch {
            return false
        }
    }

    /// kiba `CLAUDE-MIXED?`, plus an unfinished install. The live files are
    /// read first, so credentials without a config are `orphanLive` even while
    /// an install is pending. Then: an install is pending, whatever the files
    /// hold, even a config that names no account, which the install repairs;
    /// or the installed row exists, the live config names another account
    /// (email differs, or both orgs are known and differ), and the live
    /// credentials are still byte for byte that row's login. The config is
    /// decoded only for that comparison.
    public func isMixed() throws -> Bool {
        let pair = try live()
        guard try store.pending(.claude) == nil else { return true }
        guard let (config, creds) = pair, let name = try store.installed(.claude),
              let row = try store.fetch(.claude, name) else { return false }
        let id = try Self.decode(config, creds).identity
        let sameOrg = id.org.isEmpty || row.identity.org.isEmpty || id.org == row.identity.org
        guard !(name.belongs(to: id.email) && sameOrg) else { return false }
        return creds == row.login
    }

    /// The live config and credentials; nil when there are no credentials.
    /// Credentials without a config are `orphanLive`: they are some account's
    /// tokens, maybe a saved row's refresh token, and nothing says whose, so
    /// no saved login is refreshed and the live one is not replaced until the
    /// config names them.
    func live() throws -> (config: Data, creds: Data)? {
        let config = try PrivateFS.read(configFile)
        guard let creds = try secrets.read() else { return nil }
        guard let config else { throw KibaError.orphanLive(configFile) }
        return (config, creds)
    }

    /// What an install writes, and the live state it replaces.
    struct Change {
        /// The live config and credentials before; nil where there were none.
        let config: Data?
        let creds: Data?
        /// No install was pending before, so no marker says those two disagree.
        let settled: Bool
        /// The config with the row's profile spliced in, and the row's login.
        let after: Data
        let login: Data
    }

    /// What installing `n` writes, checked, and the live state it replaces.
    func prepare(_ n: SlotName) throws -> Change {
        guard let row = try store.fetch(.claude, n) else { throw KibaError.noAccount(.claude, n.raw) }
        guard let profile = row.profile, n.belongs(to: try ClaudeIdentity.fromOAuthAccount(profile).email) else {
            throw KibaError.mismatch(.claude, n.raw)
        }
        guard try JSONDoc(row.login).objectSpan(ClaudeIdentity.Key.oauth) != nil else {
            throw KibaError.badJSON(ClaudeIdentity.Key.oauth)
        }
        let config = try PrivateFS.read(configFile)
        return Change(
            config: config, creds: try secrets.read(), settled: try store.pending(.claude) == nil,
            after: try spliced(config, profile), login: row.login)
    }

    /// Makes the live config `doc`; nil removes the file a write would replace.
    func putConfig(_ doc: Data?) throws {
        guard let doc else { return try PrivateFS.removeTree(PrivateFS.writeTarget(configFile)) }
        try PrivateFS.ensurePrivateDir(configFile.deletingLastPathComponent())
        try PrivateFS.writePrivate(doc, to: configFile)
    }

    /// The config `old` with its top-level `oauthAccount` value, of any kind,
    /// replaced by `profile`; inserted before the closing brace when absent; a
    /// new document when there is no config.
    func spliced(_ old: Data?, _ profile: Data) throws -> Data {
        guard let old else { return Self.open + Self.member + profile + Self.close }
        let doc = try JSONDoc(old)
        if let span = doc.valueSpan(ClaudeIdentity.Key.account) {
            return try doc.replacing(span, with: profile).data
        }
        let (brace, hasMembers) = doc.closingBrace()
        return try doc.replacing(brace ..< brace, with: (hasMembers ? Self.comma : Data()) + Self.member + profile).data
    }
}
