import Foundation

/// The `history` table: append-only events the usage report reads. Each
/// row snapshots the account it names and never joins the saved rows; it
/// holds identity and usage metadata, never login bytes or tokens.
extension Tx {
    /// Appends a probe's outcome for the saved login `n`, observed at `at`;
    /// `identity` carries the plan committed with it, and `live` whether the
    /// probe treated the login as live.
    func appendUsage(
        _ p: Provider, _ n: SlotName, identity: Identity, usage: UsageRecord, live: Bool, at: Date
    ) throws {
        try run(
            """
            INSERT INTO history (provider, kind, at_us, name, email, org, plan, details)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, "append usage",
            [.text(p.rawValue), .text(EventKind.usage.rawValue), .int(epochMicros(at)), .text(n.raw),
             .text(identity.email), .text(identity.org), .text(identity.plan),
             .text(historyJSON(UsageDetails(usage, live: live)))])
    }

    /// Appends the completed installation of the saved login `n`, whose row
    /// holds `identity`, at `at`: the date its install notes.
    func appendSwitch(_ p: Provider, _ n: SlotName, identity: Identity, at: Date) throws {
        try run(
            """
            INSERT INTO history (provider, kind, at_us, name, email, org, plan, details)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, "append switch",
            [.text(p.rawValue), .text(EventKind.switch.rawValue), .int(epochMicros(at)), .text(n.raw),
             .text(identity.email), .text(identity.org), .text(identity.plan), .text(historyJSON(SwitchDetails()))])
    }
}

/// What a history row records.
enum EventKind: String {
    case usage
    case `switch`
}

/// A switch event's `details`: empty, since its common columns name the destination.
struct SwitchDetails: Encodable {}

/// A usage event's `details`.
struct UsageDetails: Encodable {
    let fetchedAt: Int
    let state: UsageState
    let note: String
    let live: Bool
    let limits: [WindowDetails]
    /// Absent from the JSON when nil.
    let resets: ResetOffer?

    init(_ u: UsageRecord, live: Bool) {
        fetchedAt = u.fetchedAt
        state = u.state
        note = u.note
        self.live = live
        limits = u.limits.map(WindowDetails.init)
        resets = u.resets
    }
}

/// One limit of a usage event, with the share of its window left.
struct WindowDetails: Encodable {
    let label: String
    let percent: Int
    /// Nil, JSON null, for a window with no reading.
    let left: Int?
    let resetsAt: String

    static let whole = 100

    init(_ l: Limit) {
        label = l.label
        percent = l.percent
        left = l.percent < 0 ? nil : max(0, Self.whole - l.percent)
        resetsAt = l.resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case label, percent, left, resetsAt
    }

    /// `left` is written even when nil: an unavailable reading is null, not absent.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(percent, forKey: .percent)
        try c.encode(left, forKey: .left)
        try c.encode(resetsAt, forKey: .resetsAt)
    }
}

/// `value` as history stores it: JSON with sorted keys.
func historyJSON(_ value: some Encodable) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    do {
        return String(decoding: try enc.encode(value), as: UTF8.self)
    } catch {
        preconditionFailure("history details hold only strings, integers and booleans, so they always encode: \(error)")
    }
}

/// Microseconds since the Unix epoch of `date`, rounded down.
func epochMicros(_ date: Date) -> Int {
    Int((date.timeIntervalSince1970 * Micros.perSecond).rounded(.down))
}

private enum Micros {
    static let perSecond = 1_000_000.0
}
