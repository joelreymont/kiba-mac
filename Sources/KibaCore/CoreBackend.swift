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
    /// network, the Keychain as `username`, Terminal, and the login shell's PATH.
    public init(env: [String: String], username: String) throws {
        let paths = try Paths(env: env, username: username)
        let store = try Store(paths: paths)
        let switcher = Switcher(paths: paths, store: store, http: URLSessionClient(), clock: Date.init)
        self.init(
            switcher: switcher,
            reader: StatusReader(paths: paths, store: store),
            runner: try LoginRunner(
                paths: paths, switcher: switcher, terminal: TerminalApp(), keychain: KeychainTool(account: username),
                searchPath: try Self.loginPath(env: env)))
    }

    /// The PATH of the user's login shell. An app started from Finder or a
    /// login item inherits only the system default, which lacks the CLIs.
    /// The value is printed between markers so anything the profile prints
    /// cannot pollute it.
    static func loginPath(env: [String: String]) throws -> String {
        let shell = URL(fileURLWithPath: env[Shell.variable] ?? Shell.fallback, isDirectory: false)
        let r = try Subprocess.run(shell, [Shell.loginCommand, Shell.printPath], stdin: nil, env: env, setsid: true)
        let out = String(decoding: r.stdout, as: UTF8.self)
        guard r.status == 0,
            let open = out.range(of: Shell.marker),
            let close = out.range(of: Shell.marker, range: open.upperBound..<out.endIndex)
        else {
            throw KibaError.tool(shell.lastPathComponent, r.status, String(decoding: r.stderr, as: UTF8.self))
        }
        return String(out[open.upperBound..<close.lowerBound])
    }

    private enum Shell {
        static let variable = "SHELL"
        static let fallback = "/bin/zsh"
        static let loginCommand = "-lc"
        static let marker = "<kiba-path>"
        static let printPath = "printf '%s%s%s' '\(marker)' \"$PATH\" '\(marker)'"
    }

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

    public func redeem(_ p: Provider, _ n: SlotName) async throws -> ResetOutcome {
        try await switcher.redeem(p, n)
    }
}
