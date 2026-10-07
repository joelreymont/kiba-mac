import Foundation

/// Reads what the panel shows: every provider's saved accounts and live login.
/// Never opens a write transaction. Each provider is read on its own: a
/// failure becomes that provider's `error` and leaves the others untouched.
public struct StatusReader: Sendable {
    let paths: Paths
    let store: Store

    public init(paths: Paths, store: Store) {
        self.paths = paths
        self.store = store
    }

    public func read() -> Snapshot {
        Snapshot(providers: Provider.allCases.map(status))
    }

    /// Saved accounts and the last switch's time first, so a broken live
    /// login still lists them; then the live identity and the account it is
    /// saved as. Any throw becomes `error` with no live login and what was
    /// read so far.
    func status(_ p: Provider) -> ProviderStatus {
        var accounts: [Account] = []
        var at: Int?
        do {
            accounts = try store.list(p).map { Account(name: $0.name, plan: $0.identity.plan, active: false, usage: $0.usage) }
            at = try store.installedAt(p)
            guard let live = try identity(p) else {
                return ProviderStatus(provider: p, live: nil, installedAt: at, accounts: accounts, error: nil)
            }
            let name = try store.liveName(p, live: live)
            for i in accounts.indices { accounts[i].active = accounts[i].name == name }
            return ProviderStatus(
                provider: p, live: LiveLogin(email: live.email, plan: live.plan), installedAt: at, accounts: accounts, error: nil)
        } catch {
            return ProviderStatus(provider: p, live: nil, installedAt: at, accounts: accounts, error: Self.reason(error))
        }
    }

    func identity(_ p: Provider) throws -> Identity? {
        switch p {
        case .claude: return try ClaudeLive(paths: paths, store: store, secrets: ClaudeSecrets.live(paths: paths, root: nil)).identity()
        case .codex: return try CodexLive(paths: paths, store: store).identity()
        }
    }

    /// Every core failure is a `KibaError`; anything else still shows as text.
    static func reason(_ error: any Error) -> String {
        (error as? KibaError)?.reason ?? String(describing: error)
    }
}
