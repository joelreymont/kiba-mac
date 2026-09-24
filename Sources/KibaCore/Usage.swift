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
