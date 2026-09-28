import Foundation
import KibaCore
import Observation

/// Builds the backend; a failure leaves the panel unavailable until Retry.
typealias Connect = @Sendable () throws -> any Backend

/// One control the cursor can rest on; `trigger(_:)` runs each.
enum ActionKey: Hashable, Sendable {
    /// An account row: switch to it.
    case use(Provider, SlotName)
    /// A row's limit-reset badge: asks before spending one.
    case redeem(Provider, SlotName)
    case save(Provider)
    case add(Provider)
    /// The buttons of a row asking to confirm: go ahead (Forget or Reset),
    /// and Keep.
    case confirm(Provider, SlotName)
    case keep(Provider, SlotName)
    /// Read the status again after it failed.
    case retry
    /// Clear the held notice: a result or error kept until acknowledged.
    case dismiss
    case usage
}

/// A row asking before an action it cannot take back: "Forget …?" or
/// "Use a limit reset on …?".
struct Choice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case forget
        case reset
    }

    var kind: Kind
    var provider: Provider
    var name: SlotName

    /// The account row the confirmation stands in for.
    var row: ActionKey { .use(provider, name) }

    /// The control that asked, where Keep returns the cursor.
    var origin: ActionKey {
        switch kind {
        case .forget: row
        case .reset: .redeem(provider, name)
        }
    }
}

enum Availability: Equatable {
    /// Before the first status read.
    case checking
    case ready
    case failed(String)
}

/// A provider as the panel lays it out.
struct Section: Identifiable {
    var status: ProviderStatus
    /// Rows in display order (`Rows.sorted`).
    var accounts: [Account]
    /// A live login is present, readable, and not saved.
    var canSave: Bool
    var id: Provider { status.provider }
}

/// The menu bar icon's state: one cell per provider, each drawn with its
/// own geometry so no state rests on color alone.
struct Gauge: Equatable, Sendable {
    enum Cell: Equatable, Sendable {
        /// No current account, or its usage is not known: outline only.
        case unknown
        /// Percent of the current account's headline window left, 1…100.
        case level(Int)
        /// The current account has nothing usable left: a window is at its
        /// limit, or its login is gone.
        case spent
        /// An error is showing, for this provider or for the app.
        case fault
    }

    var cells: [Cell]
    /// An error is showing: every cell is a fault, drawn in `out`.
    var alert: Bool
    var dim: Bool
}

/// The latest probe of every saved account.
struct ProbeRun: Equatable, Sendable {
    /// Epoch seconds the probe started; every record it wrote is as new.
    var at: Int
    /// Nothing failed or waited, and every provider was probed.
    var clean: Bool
    /// The usage it recorded, by provider and account.
    var records: [Provider: [SlotName: UsageRecord]]

    /// Clean, and every row `s` shows holds the usage this run recorded: a
    /// row it did not record, or one added since, leaves it partial.
    func complete(_ s: Snapshot) -> Bool {
        clean && s.providers.allSatisfy { p in
            p.accounts.allSatisfy { a in a.usage != nil && a.usage == records[p.provider]?[a.name] }
        }
    }
}

/// What an action came to. A plain confirmation fades; a held result (an
/// unexpected account, a removed login, a probe that missed accounts) and
/// every error stay until dismissed or superseded by the next action.
struct Outcome: Equatable, Sendable {
    var text: String
    var held = false
    var errors: [String] = []
    /// The providers `errors` concern; their gauge cells show a fault.
    var faults: Set<Provider> = []
}

/// The panel's state and every action it can start.
@MainActor @Observable
final class AppModel {
    private(set) var snapshot = Snapshot(providers: [])
    private(set) var sections: [Section] = []
    private(set) var availability = Availability.checking
    private(set) var refreshing = false
    private(set) var busy = false
    /// The running action's label, then its plain confirmation, which fades.
    private(set) var message = ""
    /// A result that needs attention, kept until dismissed or superseded:
    /// what the last user action came to, then what the probes since missed.
    var note: String { Self.lines(actionNote, probeNote) }
    /// The latest probe of every saved account; nil until one has run.
    private(set) var lastProbe: ProbeRun?
    private(set) var panelOpen = false
    /// The tallest the panel may be: the screen's visible height less the
    /// popover chrome, set before each show.
    private(set) var heightLimit: CGFloat = Theme.maxHeight
    private(set) var autoProbed = false
    /// The clock rows are drawn against; ticks while the panel is open.
    private(set) var now = Date()
    private(set) var cursor: ActionKey?
    /// The row showing a confirmation in place of its name and figures.
    private(set) var confirming: Choice?
    /// The row a keyboard move asks the view to scroll to; `scrollSerial`
    /// changes on every such move.
    private(set) var scrollKey: ActionKey?
    private(set) var scrollSerial = 0
    private(set) var refreshIntervalSec = Timing.interval

    /// The last failed status read; cleared by the next good one.
    private var statusError = ""
    /// The last user action's held result and failure; kept until dismissed
    /// or superseded by the next action the user starts.
    private var actionNote = ""
    private var actionError = ""
    /// The probes' held results, their save-back and provider failures and
    /// the providers those concern: a probe the user starts replaces them,
    /// the one opening the panel starts adds to them.
    private var probeNote = ""
    private var probeError = ""
    private var probeFaults: Set<Provider> = []

    var error: String { statusError.isEmpty ? Self.lines(actionError, probeError) : statusError }

    /// Closes the popover; the status item sets it.
    @ObservationIgnored var closePanel: () -> Void = {}
    /// Speaks what an action came to; the status item posts it to VoiceOver.
    @ObservationIgnored var announce: (String) -> Void = { _ in }

    @ObservationIgnored private let connect: Connect
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var backend: (any Backend)?
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var queued = false
    @ObservationIgnored private var queuedForce = false
    /// Actions waiting for the status read that follows them.
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var clearer: Task<Void, Never>?

    init(connect: @escaping Connect, defaults: UserDefaults = .standard) {
        self.connect = connect
        self.defaults = defaults
    }

    // MARK: Derived

    /// Every control a click can reach, in panel order: Dismiss while a
    /// notice is held; Retry while the status read has failed; per provider
    /// its add, its account rows, each followed by its limit-reset badge when
    /// it offers one, and its save; the usage action last. A row asking to
    /// confirm offers its go and Keep buttons in place of the row and its badge.
    var actions: [ActionKey] {
        var keys: [ActionKey] = []
        if canDismiss { keys.append(.dismiss) }
        if canRetry { keys.append(.retry) }
        for sec in sections {
            keys.append(.add(sec.id))
            for a in sec.accounts {
                let row = ActionKey.use(sec.id, a.name)
                if confirming?.row == row {
                    keys += [.confirm(sec.id, a.name), .keep(sec.id, a.name)]
                } else {
                    keys.append(row)
                    if Rows.resets(a.usage) > 0 { keys.append(.redeem(sec.id, a.name)) }
                }
            }
            if sec.canSave { keys.append(.save(sec.id)) }
        }
        if !sections.isEmpty { keys.append(.usage) }
        return keys
    }

    /// The Retry row shows while the status is unavailable and no read runs.
    var canRetry: Bool {
        guard case .failed = availability else { return false }
        return !refreshing
    }

    /// A held result or a shown action error waits for Dismiss.
    var canDismiss: Bool {
        !note.isEmpty || (statusError.isEmpty && !error.isEmpty)
    }

    /// Header meta line: the latest probe's age, and whether it reached every
    /// account; before any probe, the age of the oldest record shown.
    var meta: String {
        if busy { return Copy.working }
        if refreshing { return Copy.refreshing }
        guard availability == .ready else { return Copy.unavailable }
        if let run = lastProbe {
            return (run.complete(snapshot) ? Copy.probedAll : Copy.probedSome) + Rows.age(run.at, now: now)
        }
        let times = snapshot.providers.flatMap(\.accounts).compactMap(\.usage?.fetchedAt).filter { $0 > 0 }
        guard let oldest = times.min() else { return Copy.saved }
        return Copy.oldest + Rows.age(oldest, now: now)
    }

    /// Age of the latest probe of every account, or "" before one.
    var probeAge: String {
        lastProbe.map { Rows.age($0.at, now: now) } ?? ""
    }

    var iconTip: String {
        guard availability == .ready else { return Copy.iconIdle }
        return snapshot.providers
            .map { "\($0.provider.title): \($0.live?.email ?? Copy.none)" }
            .joined(separator: "\n")
    }

    /// A failed status read or user action paints every cell; a provider's
    /// own failure, from the status read or its latest probe, paints its cell.
    var gauge: Gauge {
        let alert = !statusError.isEmpty || !actionError.isEmpty
        let cells = Provider.allCases.map { p -> Gauge.Cell in
            let s = snapshot.providers.first { $0.provider == p }
            return alert || s?.error != nil || probeFaults.contains(p) ? .fault : Self.cell(s)
        }
        return Gauge(cells: cells, alert: alert, dim: availability != .ready)
    }

    /// The status item's accessibility value: each provider's cell in words,
    /// then every error showing.
    var iconValue: String {
        var parts = zip(Provider.allCases, gauge.cells).map { p, c in "\(p.title): \(Copy.cell(c))" }
        parts += snapshot.providers.compactMap { s in s.error.map { "\(s.provider.title): \($0)" } }
        if !error.isEmpty { parts.append(error) }
        return parts.joined(separator: Copy.partSep)
    }

    /// The current account's headline room; nothing usable while a window is
    /// used up, the login is gone, or the organization has no plan.
    private static func cell(_ p: ProviderStatus?) -> Gauge.Cell {
        guard let a = p?.accounts.first(where: \.active) else { return .unknown }
        switch Rows.state(a.usage, active: true) {
        case .blocked, .dead, .unsubscribed: return .spent
        case .unknown: return .unknown
        case .ok, .tight:
            guard let h = Rows.headline(a.usage) else { return .unknown }
            return .level(max(0, min(Timing.full, Timing.full - h.percent)))
        }
    }

    // MARK: Status

    /// First read at launch.
    func start() {
        refresh()
    }

    /// Reads the status off the main thread. Skipped within the debounce of
    /// the last good read unless forced; a call during a read queues one more.
    func refresh(force: Bool = false) {
        if refreshing {
            queued = true
            queuedForce = queuedForce || force
            return
        }
        let forced = force || queuedForce
        queued = false
        queuedForce = false
        if !forced, let last = lastRead, Date().timeIntervalSince(last) < Timing.debounce { return }
        refreshing = true
        let connect = connect, known = backend
        Task {
            let result = await Task.detached { () -> Result<(any Backend, Snapshot), any Error> in
                do {
                    let b: any Backend
                    if let known {
                        b = known
                    } else {
                        b = try connect()
                    }
                    return .success((b, b.status()))
                } catch {
                    return .failure(error)
                }
            }.value
            finish(result)
        }
    }

    /// Applies a read. Actions waiting for it resume once no read runs or
    /// is queued, so the snapshot they see postdates their work.
    private func finish(_ result: Result<(any Backend, Snapshot), any Error>) {
        let old = actions
        refreshing = false
        switch result {
        case .success(let (b, s)):
            backend = b
            lastRead = Date()
            availability = .ready
            statusError = ""
            apply(s)
        case .failure(let e):
            availability = .failed(Self.reason(e))
            statusError = Self.reason(e)
            apply(Snapshot(providers: []))
        }
        if let c = confirming, !stands(c) { confirming = nil }
        retain(old)
        if queued { refresh() }
        if !refreshing { release() }
        maybeAutoProbe()
    }

    private func apply(_ s: Snapshot) {
        guard s != snapshot else { return }
        snapshot = s
        sections = s.providers.map { p in
            Section(
                status: p,
                accounts: Rows.sorted(p.accounts),
                canSave: p.live != nil && p.error == nil && !p.accounts.contains(where: \.active))
        }
    }

    /// Forces a read; returns once it, and any read queued behind it, has
    /// applied its snapshot or failed.
    private func reread() async {
        await withCheckedContinuation { done in
            waiting.append(done)
            refresh(force: true)
        }
    }

    private func release() {
        let done = waiting
        waiting = []
        for d in done { d.resume() }
    }

    /// Keeps the cursor on its row across refreshes; when the row is gone the
    /// cursor stays at the same position.
    private func retain(_ old: [ActionKey]) {
        guard let c = cursor, !actions.contains(c) else { return }
        let i = old.firstIndex(of: c) ?? 0
        cursor = actions.isEmpty ? nil : actions[min(i, actions.count - 1)]
    }

    // MARK: Panel lifecycle

    func opened() {
        guard !panelOpen else { return }
        panelOpen = true
        cursor = nil
        confirming = nil
        autoProbed = false
        now = Date()
        refreshIntervalSec = max(Timing.minInterval, defaults.object(forKey: Timing.intervalKey) as? Int ?? Timing.interval)
        refresh()
        maybeAutoProbe()
        poller = every(.seconds(refreshIntervalSec)) { $0.refresh() }
        ticker = every(Timing.tick) { $0.now = Date() }
    }

    func closed() {
        guard panelOpen else { return }
        panelOpen = false
        poller?.cancel()
        ticker?.cancel()
        poller = nil
        ticker = nil
        keep()
    }

    /// Stale numbers cannot say which account to switch to, so each open
    /// probes once, as soon as the model shows saved accounts.
    private func maybeAutoProbe() {
        guard !autoProbed, panelOpen, !busy, availability == .ready,
              snapshot.providers.contains(where: { !$0.accounts.isEmpty }) else { return }
        autoProbed = true
        probe(.autoProbe)
    }

    private func every(_ d: Duration, _ body: @escaping @MainActor (AppModel) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: d)
                } catch {
                    return
                }
                guard let self else { return }
                body(self)
            }
        }
    }

    // MARK: Cursor

    /// Caps the panel at `height` points.
    func fit(height: CGFloat) {
        heightLimit = height
    }

    /// Hover and VoiceOver focus: moves the cursor without scrolling.
    func point(_ k: ActionKey) {
        cursor = k
    }

    /// Keyboard: moves the cursor one control and scrolls it into view.
    func move(_ delta: Int) {
        guard !actions.isEmpty else { return }
        let next: Int
        if let c = cursor, let i = actions.firstIndex(of: c) {
            next = min(max(i + delta, 0), actions.count - 1)
        } else {
            next = delta < 0 ? actions.count - 1 : 0
        }
        cursor = actions[next]
        scrollKey = cursor
        scrollSerial &+= 1
    }

    /// Return or Space on the cursor's control.
    func activate() {
        guard let c = cursor, actions.contains(c) else { return }
        trigger(c)
    }

    /// Delete on an account row: asks to forget it, as its context menu does.
    func forgetCursor() {
        guard case .use(let p, let n)? = cursor else { return }
        ask(.forget, p, n)
    }

    /// Escape: backs out of a confirmation, else closes the panel.
    func escape() {
        if confirming != nil {
            keep()
        } else {
            closePanel()
        }
    }

    // MARK: Actions

    /// Runs the control `k` names. Each action refuses while one runs;
    /// Keep (it only ends a confirmation), Dismiss (it only clears the
    /// notice) and Retry (it only rereads) always run.
    func trigger(_ k: ActionKey) {
        switch k {
        case .use(let p, let n): use(p, n)
        case .redeem(let p, let n): ask(.reset, p, n)
        case .save(let p): save(p)
        case .add(let p): add(p, email: nil)
        case .confirm(let p, let n): confirm(p, n)
        case .keep: keep()
        case .retry: refresh(force: true)
        case .dismiss: dismiss()
        case .usage: probeUsage()
        }
    }

    /// Acknowledges the held notice: its result and the action error go.
    func dismiss() {
        let old = actions
        actionNote = ""
        actionError = ""
        clearProbe()
        retain(old)
    }

    /// Switches to a saved account; a dead one is logged in again instead.
    func use(_ p: Provider, _ n: SlotName) {
        guard let a = account(p, n), !a.active else { return }
        if Rows.dead(a.usage, active: a.active) {
            add(p, email: n.email)
            return
        }
        run("Switching \(p.title) to \(n.raw)…") { b in
            try await b.use(p, n)
            return Outcome(text: "\(p.title): now \(n.raw)")
        }
    }

    func save(_ p: Provider) {
        run("Saving the current \(p.title) login…") { b in
            guard let n = try await Self.off({ try b.save(p) }) else { throw KibaError.noLive(p) }
            return Outcome(text: "Saved \(n.raw)")
        }
    }

    /// Runs the provider's login in Terminal; the panel closes first.
    func add(_ p: Provider, email: String?) {
        guard !busy else { return }
        if panelOpen {
            closePanel()
            closed()
        }
        run("Adding a \(p.title) account…") { b in
            let r = try await b.add(p, expected: email)
            if r.differs, let e = r.expected { return Outcome(text: "Added \(r.saved.raw), not \(e)", held: true) }
            return Outcome(text: "Added \(r.saved.raw)")
        }
    }

    /// Probes every provider at once.
    func probeUsage() {
        probe(.probe)
    }

    /// `.autoProbe` is the probe that opening the panel starts: it adds to
    /// what is held, so the report of an action that failed while the panel
    /// was closed stays. Nothing saved leaves no probe to date; a run that
    /// reached no account leaves the last one standing, so the meta line
    /// and the Refresh usage row keep the age of the latest actual probe.
    private func probe(_ scope: Scope) {
        let start = Int(Date().timeIntervalSince1970)
        run(Copy.probing, scope: scope) { [self] b in
            let t = Tally(await Self.probe(b), shown: snapshot)
            if t.total == 0 {
                lastProbe = nil
            } else if t.covered > 0 {
                lastProbe = ProbeRun(at: start, clean: t.clean, records: t.records)
            }
            return t.outcome
        }
    }

    /// Turns the row into its confirmation, the cursor on Keep.
    func ask(_ kind: Choice.Kind, _ p: Provider, _ n: SlotName) {
        let c = Choice(kind: kind, provider: p, name: n)
        guard !busy, stands(c) else { return }
        confirming = c
        cursor = .keep(p, n)
    }

    /// Ends the confirmation; a cursor on its buttons returns to the control
    /// that asked.
    func keep() {
        guard let c = confirming else { return }
        confirming = nil
        if let k = cursor, !actions.contains(k) { cursor = c.origin }
    }

    /// A confirmation stands while its row exists and, for a reset, still
    /// offers one.
    private func stands(_ c: Choice) -> Bool {
        guard let a = account(c.provider, c.name) else { return false }
        return c.kind == .forget || Rows.resets(a.usage) > 0
    }

    /// The confirmation's go button: Forget or Reset.
    private func confirm(_ p: Provider, _ n: SlotName) {
        guard let c = confirming, c.row == .use(p, n) else { return }
        switch c.kind {
        case .forget: forget(p, n)
        case .reset: redeem(p, n)
        }
    }

    func forget(_ p: Provider, _ n: SlotName) {
        guard !busy else { return }
        keep()
        run("Forgetting \(n.raw)…") { b in
            try await Self.off { try b.forget(p, n) }
            return Outcome(text: "Forgot \(n.raw)")
        }
    }

    /// Spends one of the row's limit resets; the provider's answer is the
    /// message, and the reread shows the row's new usage and count.
    func redeem(_ p: Provider, _ n: SlotName) {
        guard !busy else { return }
        keep()
        run("Resetting limit for \(n.raw)…") { b in
            Outcome(text: Copy.outcome(try await b.redeem(p, n), n.raw))
        }
    }

    /// Shows a failure that happened outside the panel's own actions.
    func report(_ e: KibaError) {
        fail(e.reason)
    }

    /// One action at a time: shows `label` while `work` runs, then its
    /// result or its error, and rereads the status either way; stays busy
    /// until the reread has applied, so no control acts on the rows from
    /// before the action. What the user starts supersedes everything held;
    /// the probe the panel starts on opening supersedes nothing.
    private func run(
        _ label: String, scope: Scope = .action, _ work: @escaping @MainActor (any Backend) async throws -> Outcome
    ) {
        guard !busy, let b = backend else { return }
        busy = true
        clearer?.cancel()
        message = label
        if scope != .autoProbe {
            actionNote = ""
            actionError = ""
            clearProbe()
        }
        Task {
            do {
                show(try await work(b), scope)
            } catch {
                message = ""
                fail(Self.reason(error))
            }
            await reread()
            busy = false
            maybeAutoProbe()
        }
    }

    /// Shows what an action came to and speaks it. The probe the panel
    /// starts on opening adds the held lines and errors not shown yet and
    /// speaks only those, so an open does not repeat a note over the popover.
    private func show(_ o: Outcome, _ scope: Scope) {
        let held = o.held ? o.text : ""
        var said = [o.text] + o.errors
        switch scope {
        case .action:
            actionNote = held
            // A failure reported while the action ran stays beside its result.
            actionError = Self.merge(actionError, o.errors)
            // Rows an action probed, added or removed outdate the last full probe.
            lastProbe = nil
        case .probe:
            probeNote = held
            probeError = o.errors.joined(separator: Copy.lineBreak)
            probeFaults = o.faults
        case .autoProbe:
            let shown = Set([actionNote, probeNote, actionError, probeError].flatMap(Self.split))
            let note = Self.split(held).filter { !shown.contains($0) }
            let errors = o.errors.filter { !shown.contains($0) }
            probeNote = Self.merge(probeNote, note)
            probeError = Self.merge(probeError, errors)
            probeFaults.formUnion(o.faults)
            said = note + errors
        }
        if o.held {
            message = ""
        } else {
            flash(o.text)
        }
        if !said.isEmpty { announce(said.joined(separator: Copy.lineBreak)) }
    }

    private func clearProbe() {
        probeNote = ""
        probeError = ""
        probeFaults = []
    }

    /// `a` then `b`, each when it has text.
    private static func lines(_ a: String, _ b: String) -> String {
        [a, b].filter { !$0.isEmpty }.joined(separator: Copy.lineBreak)
    }

    /// What a result supersedes: the user's action or probe, everything
    /// held; the probe the panel starts on opening, nothing.
    private enum Scope { case action, probe, autoProbe }

    private func fail(_ reason: String) {
        actionError = Self.merge(actionError, Self.split(reason))
        announce(reason)
    }

    /// `old` followed by the lines of `new` it lacks, so a failure reported
    /// from outside an action joins the one held instead of replacing it.
    private static func merge(_ old: String, _ new: [String]) -> String {
        var lines = split(old)
        for l in new where !lines.contains(l) { lines.append(l) }
        return lines.joined(separator: Copy.lineBreak)
    }

    /// The lines of `text`; none when it is empty.
    private static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: Copy.lineBreak)
    }

    private func flash(_ text: String) {
        message = text
        clearer?.cancel()
        clearer = Task { [weak self] in
            do {
                try await Task.sleep(for: Timing.messageLife)
            } catch {
                return
            }
            self?.message = ""
        }
    }

    private func account(_ p: Provider, _ n: SlotName) -> Account? {
        snapshot.providers.first { $0.provider == p }?.accounts.first { $0.name == n }
    }

    private nonisolated static func probe(_ b: any Backend) async -> [(Provider, ProbeReport)] {
        await withTaskGroup(of: (Provider, ProbeReport).self) { g in
            for p in Provider.allCases {
                g.addTask { (p, await b.probeAll(p)) }
            }
            var out: [(Provider, ProbeReport)] = []
            for await r in g { out.append(r) }
            return Provider.allCases.compactMap { p in out.first { $0.0 == p } }
        }
    }

    /// Runs blocking store work off the main thread.
    private nonisolated static func off<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(operation: work).value
    }

    private static func reason(_ e: any Error) -> String {
        (e as? KibaError)?.reason ?? String(describing: e)
    }

    private enum Timing {
        /// Status reads closer together than this are skipped unless forced.
        static let debounce: TimeInterval = 5
        static let intervalKey = "refreshIntervalSec"
        static let interval = 120
        static let minInterval = 15
        static let tick = Duration.seconds(30)
        static let messageLife = Duration.seconds(4)
        static let full = 100
    }

    /// What probing every provider came to, counted per account: refreshed
    /// (the provider answered), failed (no fresh usage), removed (a later
    /// login revoked it), waiting (the live login's token has expired; its
    /// CLI refreshes it on its next run, kiba never does), and skipped (a
    /// row shown that no outcome covers: its provider could not be probed,
    /// or its login changed before its usage was recorded).
    private struct Tally {
        var refreshed = 0
        var failed = 0
        var removed = 0
        var waiting = 0
        var skipped = 0
        /// A provider could not be probed, or an account's usage not recorded.
        var unprobed = false
        /// One line per failed or removed account.
        var lines: [String] = []
        /// Save-back and provider failures, and the providers they concern.
        var errors: [String] = []
        var faults: Set<Provider> = []
        /// The usage each account's probe came back with.
        var records: [Provider: [SlotName: UsageRecord]] = [:]

        /// Counts each account once: every row `shown` lists, and every
        /// account a report names.
        init(_ reports: [(Provider, ProbeReport)], shown: Snapshot) {
            for (p, r) in reports {
                let probed = Set(r.accounts.map(\.name))
                let rows = shown.providers.first { $0.provider == p }?.accounts ?? []
                skipped += rows.count(where: { !probed.contains($0.name) })
                for a in r.accounts {
                    switch a.outcome {
                    case .record(let u, _):
                        records[p, default: [:]][a.name] = u
                        switch u.state {
                        case .ok, .unknown, .unsubscribed:
                            refreshed += 1
                        case .expired where a.live:
                            waiting += 1
                        case .expired, .error, .revoked:
                            failed += 1
                            lines.append("\(p.title): \(a.name.raw): \(u.note)")
                        }
                    case .revoked(let note):
                        removed += 1
                        lines.append("\(p.title): removed \(a.name.raw), \(note)")
                    }
                }
                // Claude credentials without a config fail the save-back and the
                // probe for one reason: it shows once.
                let fails = [r.saveBackError, r.providerError].compactMap { $0.map { "\(p.title): \($0)" } }
                for e in fails where !errors.contains(e) { errors.append(e) }
                if !fails.isEmpty { faults.insert(p) }
                if r.providerError != nil { unprobed = true }
            }
        }

        var clean: Bool { failed == 0 && waiting == 0 && !unprobed }
        /// Accounts an outcome reached.
        var covered: Int { refreshed + failed + removed + waiting }
        var total: Int { covered + skipped }

        /// Every account refreshed, or nothing to probe, is plain; a probe
        /// that missed any account is held, with one line per failed or
        /// removed account.
        var outcome: Outcome {
            let missed = total - refreshed
            var misses: [String] = []
            if failed > 0 { misses.append("\(failed) failed") }
            if removed > 0 { misses.append("\(removed) removed") }
            if waiting > 0 { misses.append(Copy.waiting(waiting)) }
            if skipped > 0 { misses.append("\(skipped) not probed") }
            let tail = misses.joined(separator: Copy.listSep)
            let head: String
            if total == 0 {
                head = errors.isEmpty ? Copy.nothingSaved : Copy.notRefreshed
            } else if missed == 0 {
                head = "Usage refreshed for \(Copy.accounts(total))"
            } else if refreshed == 0 {
                head = "\(Copy.notRefreshed): \(tail)"
            } else {
                head = "Usage refreshed for \(refreshed) of \(Copy.accounts(total)): \(tail)"
            }
            return Outcome(
                text: ([head] + lines).joined(separator: Copy.lineBreak), held: missed > 0,
                errors: errors, faults: faults)
        }
    }

    private enum Copy {
        static let working = "Working…"
        static let refreshing = "Refreshing…"
        static let unavailable = "Unavailable"
        static let saved = "Saved logins"
        static let probedAll = "All usage probed "
        static let probedSome = "Some usage probed "
        static let oldest = "Oldest usage from "
        static let probing = "Refreshing usage for every saved account…"
        static let nothingSaved = "No saved accounts to refresh"
        static let notRefreshed = "Usage not refreshed"
        static let iconIdle = "AI accounts"
        static let none = "none"
        static let lineBreak = "\n"
        static let listSep = ", "
        static let partSep = "; "

        static func accounts(_ n: Int) -> String {
            "\(n) account" + (n == 1 ? "" : "s")
        }

        /// Live logins whose expired token their CLI, not kiba, refreshes.
        static func waiting(_ n: Int) -> String {
            n == 1 ? "1 live login waiting for its CLI" : "\(n) live logins waiting for their CLIs"
        }

        /// A gauge cell in words, for the status item's accessibility value.
        static func cell(_ c: Gauge.Cell) -> String {
            switch c {
            case .unknown: "usage unknown"
            case .level(let n): "\(n)% left"
            case .spent: "none left"
            case .fault: "error"
            }
        }

        /// What a limit-reset request came to, for the account `name`.
        static func outcome(_ o: ResetOutcome, _ name: String) -> String {
            switch o {
            case .reset: "Limit reset for \(name)"
            case .notLimited: "\(name) is not at a limit; nothing was spent"
            case .alreadyUsed: "That reset was already used"
            case .noCredit: "No limit resets left for \(name)"
            case .cooldown: "Limit resets are cooling down for \(name); try again later"
            case .ineligible: "\(name) cannot reset its limit"
            case .unavailable: "Limit resets are unavailable for \(name) right now"
            }
        }
    }
}
