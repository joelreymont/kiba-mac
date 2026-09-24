/// The login a provider's CLI is using right now.
public struct LiveLogin: Codable, Equatable, Sendable {
    public var email: String
    public var plan: String

    public init(email: String, plan: String) {
        self.email = email
        self.plan = plan
    }
}

/// A saved login and its last usage record.
public struct Account: Codable, Equatable, Sendable, Identifiable {
    public var name: SlotName
    public var plan: String
    /// The live login is this slot.
    public var active: Bool
    /// Nil until the account is probed.
    public var usage: UsageRecord?

    public var id: String { name.raw }

    public init(name: SlotName, plan: String, active: Bool, usage: UsageRecord?) {
        self.name = name
        self.plan = plan
        self.active = active
        self.usage = usage
    }
}

/// One provider as the panel shows it. `error` is the reason its live login
/// or store could not be read; the saved accounts are listed regardless.
public struct ProviderStatus: Codable, Equatable, Sendable {
    public var provider: Provider
    public var live: LiveLogin?
    public var accounts: [Account]
    public var error: String?

    public init(provider: Provider, live: LiveLogin?, accounts: [Account], error: String?) {
        self.provider = provider
        self.live = live
        self.accounts = accounts
        self.error = error
    }
}

/// Every provider's status, in panel order.
public struct Snapshot: Codable, Equatable, Sendable {
    public var providers: [ProviderStatus]

    public init(providers: [ProviderStatus]) {
        self.providers = providers
    }
}

/// A slot name travels as its raw spelling; a spelling `SlotName` rejects
/// fails the decode, so no unsafe name ever enters a snapshot.
extension SlotName: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let name = SlotName(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: KibaError.badName(raw).reason))
        }
        self = name
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}
