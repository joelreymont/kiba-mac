import Foundation

/// One allowance window of a saved account.
public struct Limit: Codable, Equatable, Sendable {
    /// `Session (5-hour)`, `Weekly (7-day)`, or `<Model> Weekly` / `<Model> Session` / `<Model>`.
    public var label: String
    /// Whole percent USED, 0…100 and beyond; negative when the window has no reading.
    public var percent: Int
    /// ISO 8601 instant the window refills, or "".
    public var resetsAt: String

    public init(label: String, percent: Int, resetsAt: String) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// Limit resets the provider will grant this account on request.
public struct ResetOffer: Codable, Equatable, Sendable {
    /// Resets available now.
    public var count: Int
    /// Claude: "cedar_ember" (banked grants) or "juniper_tide" (one per week); Codex: "".
    public var program: String
    /// Claude cedar_ember: the grant to spend; else "".
    public var grant: String

    public init(count: Int, program: String, grant: String) {
        self.count = count
        self.program = program
        self.grant = grant
    }
}

/// What the last probe learned about a saved login.
public enum UsageState: String, Codable, Sendable {
    case ok, expired, revoked, error, unknown
    /// The login works, but the organization has no plan the CLI may use.
    case unsubscribed
    /// The provider is rate limiting this login's usage checks.
    case throttled
}

/// A saved account's `usage.json`: the result of its last probe.
public struct UsageRecord: Codable, Equatable, Sendable {
    /// Epoch seconds of the probe; 0 when never fetched.
    public var fetchedAt: Int
    public var state: UsageState
    /// Why there are no limits, or what went wrong; "" when nothing to say.
    public var note: String
    public var limits: [Limit]
    /// Nil when the provider said nothing about limit resets, and in every
    /// record stored before they were read.
    public var resets: ResetOffer?

    public init(fetchedAt: Int, state: UsageState, note: String, limits: [Limit], resets: ResetOffer? = nil) {
        self.fetchedAt = fetchedAt
        self.state = state
        self.note = note
        self.limits = limits
        self.resets = resets
    }
}

extension UsageRecord {
    /// What a stored record that no longer decodes reads as.
    static let unreadable = UsageRecord(
        fetchedAt: 0, state: .unknown, note: "usage record is unreadable; refresh usage", limits: [])
}

/// The stored form of `r`: JSON with sorted keys.
func usageEncode(_ r: UsageRecord) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    do {
        return try enc.encode(r)
    } catch {
        preconditionFailure("a usage record holds only strings and integers, so it always encodes: \(error)")
    }
}

/// The record stored as `data`; `UsageRecord.unreadable` when it does not decode.
func usageDecode(_ data: Data) -> UsageRecord {
    (try? JSONDecoder().decode(UsageRecord.self, from: data)) ?? .unreadable
}
