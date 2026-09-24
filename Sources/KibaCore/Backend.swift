import Foundation

/// The one seam between the app and the account logic. `CoreBackend`
/// (Switcher, StatusReader, LoginRunner) conforms in production; a fixture
/// conforms during UI development.
public protocol Backend: Sendable {
    /// Reads every provider; never takes the store lock.
    func status() -> Snapshot
    func use(_ p: Provider, _ n: SlotName) async throws
    /// The saved name, or nil when there is no live login.
    func save(_ p: Provider) throws -> SlotName?
    func forget(_ p: Provider, _ n: SlotName) throws
    /// Never throws: failures land in the report.
    func probeAll(_ p: Provider) async -> ProbeReport
    func add(_ p: Provider, expected: String?) async throws -> AddResult
}

/// What probing one saved login produced.
public enum ProbeOutcome: Equatable, Sendable {
    /// The usage record, and the login document (refreshed when the probe
    /// renewed its tokens).
    case record(UsageRecord, doc: Data)
    /// A later login revoked this one.
    case revoked(note: String)
}

/// One provider's probe run.
public struct ProbeReport: Sendable {
    /// Saving the live login back to its slot failed; the probe went on.
    public var saveBackError: String?
    /// The provider could not be probed at all.
    public var providerError: String?
    public var accounts: [(SlotName, ProbeOutcome)]

    public init(saveBackError: String?, providerError: String?, accounts: [(SlotName, ProbeOutcome)]) {
        self.saveBackError = saveBackError
        self.providerError = providerError
        self.accounts = accounts
    }
}

/// What an added login was saved as.
public struct AddResult: Equatable, Sendable {
    public var saved: SlotName
    /// The email the user asked to sign in as, if any.
    public var expected: String?
    /// An email was expected and another account signed in.
    public var differs: Bool

    public init(saved: SlotName, expected: String?, differs: Bool) {
        self.saved = saved
        self.expected = expected
        self.differs = differs
    }
}
