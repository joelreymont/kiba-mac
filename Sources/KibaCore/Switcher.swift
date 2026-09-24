import Foundation

/// Saves, installs, forgets and probes saved logins (kiba `save`, `use`,
/// `forget`, `usage`). Every store change runs in a `Store.write`
/// transaction; `probeAll` is the one place a failure is kept per account
/// instead of thrown.
public final class Switcher: Sendable {
    let paths: Paths
    let store: Store
    let http: any HTTPClient
    let clock: Clock

    public init(paths: Paths, store: Store, http: any HTTPClient, clock: @escaping Clock) {
        self.paths = paths
        self.store = store
        self.http = http
        self.clock = clock
    }

    /// Saves the live login under the name it belongs to; nil when there is
    /// no live login. `mixed` when the live Claude files name different
    /// accounts: saving them would file one account's tokens under another.
    public func save(_ p: Provider) throws -> SlotName? {
        if try isMixed(p) { throw KibaError.mixed }
        return try saveLive(p)
    }

    /// Saves the live login back so its refreshed tokens are kept (skipped
    /// when the live files are mixed: the install repairs them) and notes it
    /// as installed, since the live files hold its login: a crash inside the
    /// install then leaves a pending install whose installed name still owns
    /// the live tokens, which `probeAll` never refreshes. Installs `n`, then
    /// probes it as the live login and records its usage. A live login that
    /// cannot be read or saved stops the switch before anything is written,
    /// so no login is overwritten unsaved. The login saved back is then
    /// probed as saved: its usage came from a live probe, which never
    /// refreshes, so an expired token would leave it looking dead.
    public func use(_ p: Provider, _ n: SlotName) async throws {
        let old = try isMixed(p) ? nil : saveLive(p)
        if let old { try store.write { try $0.noteInstalled(p, old) } }
        try live(p).install(n)
        try await probe(p, n, live: true)
        if let old, old != n { try await probe(p, old, live: false) }
    }

    /// `noAccount` when there is no such saved login.
    public func forget(_ p: Provider, _ n: SlotName) throws {
        try store.write { tx in
            guard try store.fetch(p, n) != nil else { throw KibaError.noAccount(p, n.raw) }
            try tx.remove(p, n)
        }
    }

    /// Saves the live login back, then probes every saved login and records
    /// each outcome. A save-back failure is reported and the probe goes on; a
    /// provider whose accounts or live login cannot be read is not probed at
    /// all. The live login is probed as live, so its tokens are never
    /// refreshed, and it is never removed.
    public func probeAll(_ p: Provider) async -> ProbeReport {
        var backError: String?
        var mixed = false
        do {
            mixed = try isMixed(p)
            if mixed {
                backError = KibaError.mixed.reason
            } else {
                try saveLive(p)
            }
        } catch {
            backError = StatusReader.reason(error)
        }
        let rows: [SavedLogin]
        let live: Set<SlotName>
        do {
            rows = try store.list(p)
            live = try liveNames(p, mixed: mixed)
        } catch {
            return ProbeReport(saveBackError: backError, providerError: StatusReader.reason(error), accounts: [])
        }
        var accounts: [(SlotName, ProbeOutcome)] = []
        var unrecorded: [String] = []
        for row in rows {
            let isLive = live.contains(row.name)
            let outcome = await run(p, row, live: isLive)
            do {
                try record(p, row, outcome, live: isLive)
            } catch {
                unrecorded.append("\(row.name.raw): usage not recorded: \(StatusReader.reason(error))")
            }
            accounts.append((row.name, outcome))
        }
        let providerError = unrecorded.isEmpty ? nil : unrecorded.joined(separator: Self.joiner)
        return ProbeReport(saveBackError: backError, providerError: providerError, accounts: accounts)
    }

    /// Saves the login a provider login left in the throwaway home `root`
    /// (Claude: `root/.claude/.claude.json` plus `claudeCreds`; Codex:
    /// `root/.codex/auth.json`) under the name it belongs to. `noLive` when
    /// nothing is there.
    public func importLogin(_ p: Provider, root: URL, claudeCreds: Data?) throws -> SlotName {
        let files: any LiveFiles
        switch p {
        case .claude: files = ClaudeLive(paths: paths, store: store, secrets: MemorySecret(claudeCreds), root: root)
        case .codex: files = CodexLive(paths: paths, store: store, root: root)
        }
        guard let n = try put(p, files) else { throw KibaError.noLive(p) }
        return n
    }

    /// Probes the saved login `n` and records the outcome; `noAccount` when
    /// there is no such login.
    @discardableResult
    func probe(_ p: Provider, _ n: SlotName, live: Bool) async throws -> ProbeOutcome {
        guard let row = try store.fetch(p, n) else { throw KibaError.noAccount(p, n.raw) }
        let outcome = await run(p, row, live: live)
        try record(p, row, outcome, live: live)
        return outcome
    }

    /// The live login saved under the name it belongs to; nil when there is none.
    @discardableResult
    func saveLive(_ p: Provider) throws -> SlotName? {
        try put(p, live(p))
    }

    /// Puts the login `files` reads under the name `liveName` gives its
    /// identity, in one transaction; nil when there is no login.
    func put(_ p: Provider, _ files: any LiveFiles) throws -> SlotName? {
        guard let id = try files.identity() else { return nil }
        return try store.write { tx in
            let n = try store.liveName(p, live: id)
            try files.save(to: n, tx)
            return n
        }
    }

    /// Only Claude keeps the account and the tokens in two files that can disagree.
    func isMixed(_ p: Provider) throws -> Bool {
        switch p {
        case .claude: return try claude().isMixed()
        case .codex: return false
        }
    }

    /// The saved names whose tokens the CLI is using: the live identity's
    /// name, and, while the live Claude files are mixed, the installed name,
    /// whose tokens are still the live credentials.
    func liveNames(_ p: Provider, mixed: Bool) throws -> Set<SlotName> {
        var names: Set<SlotName> = []
        if let id = try live(p).identity() { names.insert(try store.liveName(p, live: id)) }
        if mixed, let installed = try store.installed(p) { names.insert(installed) }
        return names
    }

    func live(_ p: Provider) -> any LiveFiles {
        switch p {
        case .claude: return claude()
        case .codex: return CodexLive(paths: paths, store: store)
        }
    }

    /// The live Claude login, its credential store chosen by what exists now.
    func claude() -> ClaudeLive {
        ClaudeLive(paths: paths, store: store, secrets: ClaudeSecrets.live(paths: paths, root: nil))
    }

    func run(_ p: Provider, _ row: SavedLogin, live: Bool) async -> ProbeOutcome {
        let input = ProbeInput(provider: p, name: row.name, doc: row.login, live: live)
        switch p {
        case .claude: return await ClaudeProbe(http: http, clock: clock).run(input)
        case .codex: return await CodexProbe(http: http, clock: clock).run(input)
        }
    }

    /// Writes a probe's outcome: the usage record and any refreshed login, or
    /// the removal of a saved login the provider revoked. The live login is
    /// never removed: a revoked one keeps its row with the revocation as its
    /// usage, because the live files are what to fix.
    func record(_ p: Provider, _ row: SavedLogin, _ outcome: ProbeOutcome, live: Bool) throws {
        try store.write { tx in
            switch outcome {
            case .record(let usage, let doc):
                try tx.setUsage(p, row.name, usage)
                if doc != row.login { try tx.setLogin(p, row.name, doc) }
            case .revoked(let note):
                guard live else { return try tx.remove(p, row.name) }
                let usage = UsageRecord(fetchedAt: epochSeconds(clock()), state: .revoked, note: note, limits: [])
                try tx.setUsage(p, row.name, usage)
            }
        }
    }

    /// Separates the per-account failures of one probe run.
    static let joiner = "; "
}

/// The files one provider's login lives in: the live ones, or a throwaway
/// home's after `add`.
protocol LiveFiles {
    func identity() throws -> Identity?
    func save(to n: SlotName, _ tx: Tx) throws
    func install(_ n: SlotName) throws
}

extension ClaudeLive: LiveFiles {}
extension CodexLive: LiveFiles {}
