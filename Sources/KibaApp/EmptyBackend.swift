import KibaCore

/// Stands in for `CoreBackend` until the core lands: no saved accounts, and
/// every provider says the core is missing.
struct EmptyBackend: Backend {
    static let note = "core not wired yet"

    func status() -> Snapshot {
        Snapshot(providers: Provider.allCases.map {
            ProviderStatus(provider: $0, live: nil, accounts: [], error: Self.note)
        })
    }

    func use(_ p: Provider, _ n: SlotName) async throws {
        throw KibaError.noAccount(p, n.raw)
    }

    func save(_ p: Provider) throws -> SlotName? {
        nil
    }

    func forget(_ p: Provider, _ n: SlotName) throws {
        throw KibaError.noAccount(p, n.raw)
    }

    func probeAll(_ p: Provider) async -> ProbeReport {
        ProbeReport(saveBackError: nil, providerError: Self.note, accounts: [])
    }

    func add(_ p: Provider, expected: String?) async throws -> AddResult {
        throw KibaError.io(Self.note)
    }
}
