import Foundation
import KibaCore
import Observation

/// Builds the backend; a failure leaves the panel unavailable until Retry.
typealias Connect = @Sendable () throws -> any Backend

/// One row the cursor can rest on, in panel order.
enum ActionKey: Hashable, Sendable {
    case use(Provider, SlotName)
    case save(Provider)
    case add(Provider)
    case usage
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

/// The menu bar icon's state.
struct Gauge: Equatable, Sendable {
    enum Cell: Equatable, Sendable {
        case unknown
        /// Fraction of the active account's headline window left, 0…1.
        case level(Double)
    }

    var cells: [Cell]
    var alert: Bool
    var dim: Bool
}

/// The panel's state and every action it can start.
@MainActor @Observable
final class AppModel {
    private(set) var snapshot = Snapshot(providers: [])
    private(set) var sections: [Section] = []
    private(set) var actions: [ActionKey] = []
    private(set) var availability = Availability.checking
    private(set) var refreshing = false
    private(set) var busy = false
    private(set) var message = ""
    private(set) var panelOpen = false
    /// The tallest the panel may be: the screen's visible height less the
    /// popover chrome, set before each show.
    private(set) var heightLimit: CGFloat = Theme.maxHeight
    private(set) var autoProbed = false
    /// The clock rows are drawn against; ticks while the panel is open.
    private(set) var now = Date()
    private(set) var cursor: ActionKey?
    /// The account row showing "Forget …? Forget / Keep".
    private(set) var forgetting: ActionKey?
    /// The row a keyboard move asks the view to scroll to; `scrollSerial`
    /// changes on every such move.
    private(set) var scrollKey: ActionKey?
    private(set) var scrollSerial = 0
    private(set) var refreshIntervalSec = Timing.interval

    /// The last failed status read; cleared by the next good one.
    private var statusError = ""
    /// The last failed action; cleared by the next action or on close.
    private var actionError = ""

    var error: String { statusError.isEmpty ? actionError : statusError }

    /// Closes the popover; the status item sets it.
    @ObservationIgnored var closePanel: () -> Void = {}

    @ObservationIgnored private let connect: Connect
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var backend: (any Backend)?
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var queued = false
    @ObservationIgnored private var queuedForce = false
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var clearer: Task<Void, Never>?

    init(connect: @escaping Connect, defaults: UserDefaults = .standard) {
        self.connect = connect
        self.defaults = defaults
    }

    // MARK: Derived

    /// Header meta line.
    var meta: String {
        if busy { return Copy.working }
        if refreshing { return Copy.refreshing }
        guard availability == .ready else { return Copy.unavailable }
        let age = usageAge
        return age.isEmpty ? Copy.saved : "Usage probed \(age)"
    }

    /// Age of the newest usage record anywhere, or "" when none exists.
    var usageAge: String {
        var newest = 0
        for p in snapshot.providers {
            for a in p.accounts { newest = max(newest, a.usage?.fetchedAt ?? 0) }
        }
        return newest > 0 ? Rows.age(newest, now: now) : ""
    }

    var iconTip: String {
        guard availability == .ready else { return Copy.iconIdle }
        return snapshot.providers
            .map { "\($0.provider.title): \($0.live?.email ?? Copy.none)" }
            .joined(separator: "\n")
    }

    var gauge: Gauge {
        let cells = Provider.allCases.map { p in
            snapshot.providers.first { $0.provider == p }.map(Self.cell) ?? .unknown
        }
        return Gauge(cells: cells, alert: !error.isEmpty, dim: availability != .ready)
    }

    /// The active account's headline room; none left while a window is used up.
    private static func cell(_ p: ProviderStatus) -> Gauge.Cell {
        guard let a = p.accounts.first(where: \.active) else { return .unknown }
        switch Rows.state(a.usage, active: true) {
        case .blocked, .dead: return .level(0)
        case .unknown: return .unknown
        case .ok, .tight:
            guard let h = Rows.headline(a.usage) else { return .unknown }
            return .level(Double(min(max(Timing.full - h.percent, 0), Timing.full)) / Double(Timing.full))
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

    private func finish(_ result: Result<(any Backend, Snapshot), any Error>) {
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
        if queued { refresh() }
        maybeAutoProbe()
    }

    private func apply(_ s: Snapshot) {
        guard s != snapshot else { return }
        let old = actions
        snapshot = s
        sections = s.providers.map { p in
            Section(
                status: p,
                accounts: Rows.sorted(p.accounts),
                canSave: p.live != nil && p.error == nil && !p.accounts.contains(where: \.active))
        }
        var keys: [ActionKey] = []
        for sec in sections {
            keys.append(.add(sec.id))
            keys += sec.accounts.map { .use(sec.id, $0.name) }
            if sec.canSave { keys.append(.save(sec.id)) }
        }
        if !sections.isEmpty { keys.append(.usage) }
        actions = keys
        retain(old)
        if let f = forgetting, !actions.contains(f) { forgetting = nil }
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
        forgetting = nil
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
        actionError = ""
        forgetting = nil
    }

    /// Stale numbers cannot say which account to switch to, so each open
    /// probes once, as soon as the model shows saved accounts.
    private func maybeAutoProbe() {
        guard !autoProbed, panelOpen, !busy, availability == .ready,
              snapshot.providers.contains(where: { !$0.accounts.isEmpty }) else { return }
        autoProbed = true
        probe(clearing: false)
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

    /// Hover: moves the cursor without scrolling.
    /// Caps the panel at `height` points.
    func fit(height: CGFloat) {
        heightLimit = height
    }

    func point(_ k: ActionKey) {
        cursor = k
    }

    /// Keyboard: moves the cursor one row and scrolls it into view.
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

    /// Return on the cursor row. A row asking to be forgotten takes only its
    /// own buttons, so Return never forgets or switches by accident.
    func activate() {
        guard let c = cursor, c != forgetting else { return }
        trigger(c)
    }

    /// Escape: backs out of a forget confirmation, else closes the panel.
    func escape() {
        if forgetting != nil {
            forgetting = nil
        } else {
            closePanel()
        }
    }

    // MARK: Actions

    func trigger(_ k: ActionKey) {
        guard !busy else { return }
        switch k {
        case .use(let p, let n): use(p, n)
        case .save(let p): save(p)
        case .add(let p): add(p, email: nil)
        case .usage: probeUsage()
        }
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
            return "\(p.title): now \(n.raw)"
        }
    }

    func save(_ p: Provider) {
        run("Saving the current \(p.title) login…") { b in
            guard let n = try await Self.off({ try b.save(p) }) else { throw KibaError.noLive(p) }
            return "Saved \(n.raw)"
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
            if r.differs, let e = r.expected { return "Added \(r.saved.raw), not \(e)" }
            return "Added \(r.saved.raw)"
        }
    }

    /// Probes every provider at once.
    func probeUsage() {
        probe(clearing: true)
    }

    /// `clearing` false keeps an error the user has not seen yet: the probe
    /// that opening the panel starts must not wipe the report of an action
    /// that failed while the panel was closed.
    private func probe(clearing: Bool) {
        run("Refreshing usage for every saved account…", clearing: clearing) { [weak self] b in
            let reports = await Self.probe(b)
            var probed = 0
            var notes: [String] = []
            var problems: [String] = []
            for (p, r) in reports {
                for (n, o) in r.accounts {
                    switch o {
                    case .record: probed += 1
                    case .revoked(let note): notes.append("\(p.title): removed \(n.raw), \(note)")
                    }
                }
                if let e = r.saveBackError { problems.append("\(p.title): \(e)") }
                if let e = r.providerError { problems.append("\(p.title): \(e)") }
            }
            if !problems.isEmpty { self?.actionError = problems.joined(separator: "\n") }
            let head = "Usage refreshed for \(probed) account" + (probed == 1 ? "" : "s")
            return ([head] + notes).joined(separator: "\n")
        }
    }

    func askForget(_ p: Provider, _ n: SlotName) {
        guard !busy else { return }
        forgetting = .use(p, n)
        cursor = forgetting
    }

    func keep() {
        forgetting = nil
    }

    func forget(_ p: Provider, _ n: SlotName) {
        forgetting = nil
        run("Forgetting \(n.raw)…") { b in
            try await Self.off { try b.forget(p, n) }
            return "Forgot \(n.raw)"
        }
    }

    /// Shows a failure that happened outside the panel's own actions.
    func report(_ reason: String) {
        actionError = reason
    }

    /// Shows a passing note in the message line.
    func say(_ text: String) {
        flash(text)
    }

    /// One action at a time: shows `label` while `work` runs, then its
    /// result or its error, and rereads the status either way. A new action
    /// clears the last action's error unless `clearing` is false.
    private func run(
        _ label: String, clearing: Bool = true, _ work: @escaping @MainActor (any Backend) async throws -> String
    ) {
        guard !busy, let b = backend else { return }
        busy = true
        clearer?.cancel()
        message = label
        if clearing { actionError = "" }
        Task {
            do {
                flash(try await work(b))
            } catch {
                message = ""
                actionError = Self.reason(error)
            }
            busy = false
            refresh(force: true)
        }
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

    private enum Copy {
        static let working = "Working…"
        static let refreshing = "Refreshing…"
        static let unavailable = "Unavailable"
        static let saved = "Saved logins"
        static let iconIdle = "AI accounts"
        static let none = "none"
    }
}
