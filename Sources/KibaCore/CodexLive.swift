import Foundation

/// The login Codex is using: one `auth.json` that both names the account and
/// holds the tokens.
public struct CodexLive {
    let paths: Paths
    let store: Store
    let root: URL?

    /// `root` reads a throwaway home instead of the live one.
    public init(paths: Paths, store: Store, root: URL? = nil) {
        self.paths = paths
        self.store = store
        self.root = root
    }

    var authFile: URL { paths.codexAuthFile(root: root) }

    /// Nil when `auth.json` is missing.
    public func identity() throws -> Identity? {
        guard let auth = try PrivateFS.read(authFile) else { return nil }
        return try CodexIdentity.fromAuth(auth)
    }

    /// Puts the live `auth.json` bytes under `n`, with the identity read from
    /// those same bytes. `mismatch` when the live login no longer belongs to `n`.
    public func save(to n: SlotName, _ tx: Tx) throws {
        guard let auth = try PrivateFS.read(authFile) else { throw KibaError.noLive(.codex) }
        let id = try CodexIdentity.fromAuth(auth)
        guard n.belongs(to: id.email) else { throw KibaError.mismatch(.codex, n.raw) }
        try tx.put(.codex, SavedLogin(name: n, identity: id, login: auth, profile: nil, usage: nil))
    }

    /// kiba `CODEX-INSTALL`, in one transaction so the row read is the row
    /// installed: the row must exist (`noAccount`) and name an email `n`
    /// belongs to (`mismatch`); its login becomes the live `auth.json`.
    public func install(_ n: SlotName) throws {
        try store.write { tx in
            guard let row = try store.fetch(.codex, n) else { throw KibaError.noAccount(.codex, n.raw) }
            guard n.belongs(to: try CodexIdentity.fromAuth(row.login).email) else { throw KibaError.mismatch(.codex, n.raw) }
            try PrivateFS.ensurePrivateDir(authFile.deletingLastPathComponent())
            try PrivateFS.writePrivate(row.login, to: authFile)
            try tx.noteInstalled(.codex, n)
        }
    }
}
