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

/// What the last probe learned about a saved login.
public enum UsageState: String, Codable, Sendable {
    case ok, expired, revoked, error, unknown
}

/// A saved account's `usage.json`: the result of its last probe.
public struct UsageRecord: Codable, Equatable, Sendable {
    /// Epoch seconds of the probe; 0 when never fetched.
    public var fetchedAt: Int
    public var state: UsageState
    /// Why there are no limits, or what went wrong; "" when nothing to say.
    public var note: String
    public var limits: [Limit]

    public init(fetchedAt: Int, state: UsageState, note: String, limits: [Limit]) {
        self.fetchedAt = fetchedAt
        self.state = state
        self.note = note
        self.limits = limits
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
