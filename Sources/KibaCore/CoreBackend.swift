import Foundation

/// The production `Backend`: status from `StatusReader`, actions through
/// `Switcher`, new accounts through `LoginRunner`.
public struct CoreBackend: Backend {
    let switcher: Switcher
    let reader: StatusReader
    let runner: LoginRunner

    public init(switcher: Switcher, reader: StatusReader, runner: LoginRunner) {
        self.switcher = switcher
        self.reader = reader
        self.runner = runner
    }

    /// Everything real: paths from `env`, the store under its `HOME`, the
    /// network, the Keychain as `username`, Terminal, and `env`'s `PATH`.
    public init(env: [String: String], username: String) throws {
        let paths = try Paths(env: env, username: username)
        let store = try Store(paths: paths)
        let switcher = Switcher(paths: paths, store: store, http: URLSessionClient(), clock: Date.init)
        self.init(
            switcher: switcher,
            reader: StatusReader(paths: paths, store: store),
            runner: LoginRunner(
                paths: paths, switcher: switcher, terminal: TerminalApp(), lister: KeychainTool(account: username),
                searchPath: env[Self.pathVar] ?? ""))
    }

    static let pathVar = "PATH"

    public func status() -> Snapshot {
        reader.read()
    }

    public func use(_ p: Provider, _ n: SlotName) async throws {
        try await switcher.use(p, n)
    }

    public func save(_ p: Provider) throws -> SlotName? {
        try switcher.save(p)
    }

    public func forget(_ p: Provider, _ n: SlotName) throws {
        try switcher.forget(p, n)
    }

    public func probeAll(_ p: Provider) async -> ProbeReport {
        await switcher.probeAll(p)
    }

    public func add(_ p: Provider, expected: String?) async throws -> AddResult {
        try await runner.add(p, expected: expected)
    }
}
