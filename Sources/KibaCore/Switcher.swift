import Foundation
import os

/// Saves, installs, forgets and probes saved logins (kiba `save`, `use`,
/// `forget`, `usage`), and spends their limit resets. Every store change runs in a `Store.write`
/// transaction; `probeAll` is the one place a failure is kept per account
/// instead of thrown. Each provider's operations run one at a time, in the
/// order they began, each to its end across every network wait: a probe
/// spending a saved login's refresh token finishes before a switch can make
/// that login live. The synchronous ones block their thread while they wait.
public final class Switcher: Sendable {
    let paths: Paths
    let store: Store
    let http: any HTTPClient
    let clock: Clock
    let claudeOps = Serial()
    let codexOps = Serial()

    public init(paths: Paths, store: Store, http: any HTTPClient, clock: @escaping Clock) {
        self.paths = paths
        self.store = store
        self.http = http
        self.clock = clock
    }

    /// Saves the live login under the name it belongs to; nil when there is
    /// no live login. `mixed` when the live Claude files name different
    /// accounts: saving them would file one account's tokens under another;
    /// `unrestored` while an add's login may still hold the live item.
    public func save(_ p: Provider) throws -> SlotName? {
        ops(p).enterBlocking()
        defer { ops(p).leave() }
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
        await ops(p).enter()
        defer { ops(p).leave() }
        let old: SlotName?
        do {
            old = try saveLive(p)
        } catch KibaError.mixed {
            old = nil
        }
        if let old { try store.write { try $0.noteInstalled(p, old) } }
        try live(p).install(n)
        try await probeInTurn(p, n, live: true)
        if let old, old != n { try await probeInTurn(p, old, live: false) }
    }

    /// `noAccount` when there is no such saved login.
    public func forget(_ p: Provider, _ n: SlotName) throws {
        ops(p).enterBlocking()
        defer { ops(p).leave() }
        try store.write { tx in
            guard try store.fetch(p, n) != nil else { throw KibaError.noAccount(p, n.raw) }
            try tx.remove(p, n)
        }
    }

    /// Saves the live login back, then probes every saved login and records
    /// each outcome. A save-back failure is reported and the probe goes on; a
    /// provider whose accounts or live login cannot be read, whose install is
    /// pending, or whose add's live item waits to go back is not probed at
    /// all. The live login is probed as live, so its tokens are never
    /// refreshed. No outcome removes a login. An outcome whose row was replaced
    /// or forgotten meanwhile is neither written nor reported; one whose
    /// write failed is named in the provider error only.
    public func probeAll(_ p: Provider) async -> ProbeReport {
        await ops(p).enter()
        defer { ops(p).leave() }
        var backError: String?
        var mixed = false
        do {
            try saveLive(p)
        } catch {
            backError = StatusReader.reason(error)
            mixed = error as? KibaError == .mixed
        }
        let rows: [SavedLogin]
        let live: Set<SlotName>
        do {
            rows = try store.list(p)
            live = try liveNames(p, mixed: mixed)
        } catch {
            return ProbeReport(saveBackError: backError, providerError: StatusReader.reason(error), accounts: [])
        }
        var accounts: [Probed] = []
        var unrecorded: [String] = []
        for row in rows {
            let isLive = live.contains(row.name)
            let outcome = await run(p, row, live: isLive)
            do {
                guard try record(p, row, outcome) else { continue }
                accounts.append(Probed(name: row.name, outcome: outcome, live: isLive))
            } catch {
                unrecorded.append("\(row.name.raw): usage not recorded: \(StatusReader.reason(error))")
            }
        }
        let providerError = unrecorded.isEmpty ? nil : unrecorded.joined(separator: Self.joiner)
        return ProbeReport(saveBackError: backError, providerError: providerError, accounts: accounts)
    }

    /// Saves the login a provider login left in the throwaway home `root`
    /// (Claude: `root/.claude/.claude.json` plus `claudeCreds`; Codex:
    /// `root/.codex/auth.json`) under the name it belongs to, for an add that
    /// holds `p`'s turn. `noLive` when nothing is there.
    func importInTurn(_ p: Provider, root: URL, claudeCreds: Data?) throws -> SlotName {
        let files: any LiveFiles
        switch p {
        case .claude: files = ClaudeLive(paths: paths, store: store, secrets: MemorySecret(claudeCreds), root: root)
        case .codex: files = CodexLive(paths: paths, store: store, root: root)
        }
        guard let n = try put(p, files) else { throw KibaError.noLive(p) }
        return n
    }

    /// Spends one limit reset of the saved login `n`, then probes it again so
    /// its usage and offer show the result. `noAccount` when there is no such
    /// login, `noResets` when its last probe offered none, `unrepaired` while
    /// an install is pending, `unrestored` while an add's live item waits to
    /// go back. A saved login's token is refreshed when it has expired or is
    /// rejected, and the new one is kept even when the reset then fails,
    /// unless the row was replaced meanwhile; a live login's never is, so a
    /// live name is decided as `probeAll` decides it.
    public func redeem(_ p: Provider, _ n: SlotName) async throws -> ResetOutcome {
        await ops(p).enter()
        defer { ops(p).leave() }
        guard let row = try store.fetch(p, n) else { throw KibaError.noAccount(p, n.raw) }
        guard let offer = row.usage?.resets, offer.count > 0 else { throw KibaError.noResets(p, n.raw) }
        let live = try liveNames(p, mixed: isMixed(p)).contains(n)
        let input = ProbeInput(provider: p, name: n, doc: row.login, live: live)
        let spent: Redemption
        switch p {
        case .claude: spent = await ClaudeProbe(http: http, clock: clock).redeem(input, offer: offer, org: row.identity.org)
        case .codex: spent = await CodexProbe(http: http, clock: clock).redeem(input)
        }
        if spent.doc != row.login { _ = try unchanged(p, row) { try $0.setLogin(p, n, spent.doc) } }
        let outcome = try spent.result.get()
        try await probeInTurn(p, n, live: live)
        return outcome
    }

    /// Probes the saved login `n` and records the outcome, for an operation
    /// that holds `p`'s turn; `noAccount` when there is no such login.
    @discardableResult
    func probeInTurn(_ p: Provider, _ n: SlotName, live: Bool) async throws -> ProbeOutcome {
        guard let row = try store.fetch(p, n) else { throw KibaError.noAccount(p, n.raw) }
        let outcome = await run(p, row, live: live)
        try record(p, row, outcome)
        return outcome
    }

    /// The turn `p`'s operations take one at a time.
    func ops(_ p: Provider) -> Serial {
        switch p {
        case .claude: return claudeOps
        case .codex: return codexOps
        }
    }

    /// The live login saved under the name it belongs to; nil when there is
    /// none. `unrestored` or `mixed`, with nothing saved, while an add's
    /// record of the live item waits or the live Claude files name different
    /// accounts. The checks and the read run in the transaction that saves:
    /// its write lock holds off another process's install, which writes both
    /// live files in one transaction, so no half of it is saved.
    @discardableResult
    func saveLive(_ p: Provider) throws -> SlotName? {
        try store.write { tx in
            try requireRestored(p)
            if try isMixed(p) { throw KibaError.mixed }
            return try put(p, live(p), tx)
        }
    }

    /// `put` in a transaction of its own.
    func put(_ p: Provider, _ files: any LiveFiles) throws -> SlotName? {
        try store.write { try put(p, files, $0) }
    }

    /// Puts the login `files` hold under the name `liveName` gives its
    /// identity, in `tx`; nil when there is no login. One read serves both:
    /// the identity chooses the slot for the very bytes saved, so a login
    /// rewritten meanwhile cannot land under another's name.
    func put(_ p: Provider, _ files: any LiveFiles, _ tx: Tx) throws -> SlotName? {
        guard let live = try files.login() else { return nil }
        let n = try store.liveName(p, live: live.identity)
        try tx.put(p, SavedLogin(name: n, identity: live.identity, login: live.login, profile: live.profile, usage: nil))
        return n
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
    /// whose tokens are still the live credentials. `unrestored` while an
    /// add's record of the live item waits. `unrepaired` while an install is
    /// pending: a failed repair may have left any saved login's tokens live,
    /// and a later one may have renamed the marker, so no saved name is known
    /// not to be live until `use` completes an install.
    func liveNames(_ p: Provider, mixed: Bool) throws -> Set<SlotName> {
        try requireRestored(p)
        var names: Set<SlotName> = []
        if let id = try live(p).identity() { names.insert(try store.liveName(p, live: id)) }
        if let pending = try store.pending(p) { throw KibaError.unrepaired(p, pending.raw) }
        if mixed, let installed = try store.installed(p) { names.insert(installed) }
        return names
    }

    /// `unrestored` while the store holds an add's record of the live item:
    /// until `LoginRunner` puts it back or finds it untouched, it may hold
    /// the tokens that add's login wrote, which no saved name owns.
    func requireRestored(_ p: Provider) throws {
        guard try store.adding(p) == nil else { throw KibaError.unrestored(p) }
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

    /// Writes a probe's outcome: the usage record and any refreshed login. A
    /// login the provider revoked keeps its row, dead, so the account stays
    /// listed until the user forgets it. False, with nothing written, when
    /// the row no longer holds the login the probe read.
    @discardableResult
    func record(_ p: Provider, _ row: SavedLogin, _ outcome: ProbeOutcome) throws -> Bool {
        try unchanged(p, row) { tx in
            try tx.setUsage(p, row.name, outcome.usage)
            if outcome.doc != row.login { try tx.setLogin(p, row.name, outcome.doc) }
        }
    }

    /// Runs `body` in one transaction while the row named `row.name` still
    /// holds the login `row` was read with; false, with nothing written, once
    /// another write has replaced or removed it.
    func unchanged(_ p: Provider, _ row: SavedLogin, _ body: (Tx) throws -> Void) throws -> Bool {
        try store.write { tx in
            guard try store.fetch(p, row.name)?.login == row.login else { return false }
            try body(tx)
            return true
        }
    }

    /// Separates the per-account failures of one probe run.
    static let joiner = "; "
}

/// The files one provider's login lives in: the live ones, or a throwaway
/// home's after `add`.
protocol LiveFiles {
    func identity() throws -> Identity?
    func login() throws -> LoginRead?
    func install(_ n: SlotName) throws
}

/// A login as one read of its files: what `put` saves, less the name.
struct LoginRead {
    let identity: Identity
    let login: Data
    let profile: Data?
}

extension ClaudeLive: LiveFiles {}
extension CodexLive: LiveFiles {}

/// Operations that must not overlap: one runs at a time, the rest wait in
/// the order they came, and a turn lasts across suspension points.
final class Serial: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Queue())

    private struct Queue {
        var busy = false
        var waiting: [@Sendable () -> Void] = []
    }

    /// Suspends until it is the caller's turn.
    func enter() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if take({ c.resume() }) { c.resume() }
        }
    }

    /// Blocks the thread until it is the caller's turn.
    func enterBlocking() {
        let woken = DispatchSemaphore(value: 0)
        if !take({ woken.signal() }) { woken.wait() }
    }

    /// Ends the caller's turn and hands it to the first waiter, if any.
    func leave() {
        let next = state.withLock { q -> (@Sendable () -> Void)? in
            guard !q.waiting.isEmpty else {
                q.busy = false
                return nil
            }
            return q.waiting.removeFirst()
        }
        next?()
    }

    /// Takes the turn when it is free (true); else queues `wake` to run
    /// when the turn is handed over.
    private func take(_ wake: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { q in
            guard q.busy else {
                q.busy = true
                return true
            }
            q.waiting.append(wake)
            return false
        }
    }
}
