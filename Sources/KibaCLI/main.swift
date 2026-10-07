import Foundation
import KibaCore

// `kiba`: Kiba's saved accounts for the Claude Code auto-switch mod, through
// KibaCore on the app's own store and turns. `status --json` prints the
// snapshot, `usage <provider>` probes the saved logins, `use <provider>
// <name>` switches the live one. Exit 0 when done, 1 with the reason on
// stderr when it failed, 64 with the synopsis for a bad command line.

/// How long a command waits for the app or another `kiba` to leave a
/// provider's turn: two minutes. Once it holds the turn it runs to the end.
let turnWait = Duration.seconds(120)

/// The command lines `kiba` takes, on one line.
let synopsis = {
    let p = Provider.allCases.map(\.rawValue).joined(separator: "|")
    return "usage: kiba status --json | kiba usage <\(p)> | kiba use <\(p)> <name>"
}()

/// What the command line asks for.
enum Command {
    case status
    case usage(Provider)
    case use(Provider, SlotName)

    /// Nil unless `args` is `status --json`, `usage <provider>`, or
    /// `use <provider> <name>` with a name `SlotName` accepts.
    init?(_ args: [String]) {
        if args == [Word.status, Word.json] {
            self = .status
        } else if args.count == 2, args[0] == Word.usage, let p = Provider(rawValue: args[1]) {
            self = .usage(p)
        } else if args.count == 3, args[0] == Word.use, let p = Provider(rawValue: args[1]), let n = SlotName(args[2]) {
            self = .use(p, n)
        } else {
            return nil
        }
    }
}

/// The words of the command lines.
enum Word {
    static let status = "status"
    static let json = "--json"
    static let usage = "usage"
    static let use = "use"
}

/// The snapshot's members the `left` pass walks, and the one it adds.
enum Key {
    static let providers = "providers"
    static let accounts = "accounts"
    static let usage = "usage"
    static let limits = "limits"
    static let left = "left"
}

/// A JSON object as `JSONSerialization` reads it.
typealias Object = [String: Any]

/// `snap` as `Snapshot` encodes, keys sorted, with `left` on every limit
/// `Rows.figures` gives a figure under its label: the percent left that the
/// panel shows.
func json(_ snap: Snapshot) throws -> Data {
    var root: Object = shaped(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)))
    var providers: [Object] = shaped(root[Key.providers])
    for (i, status) in snap.providers.enumerated() {
        var accounts: [Object] = shaped(providers[i][Key.accounts])
        for (j, account) in status.accounts.enumerated() {
            guard let u = account.usage else { continue }
            let figures = Rows.figures(status.provider, u)
            var usage: Object = shaped(accounts[j][Key.usage])
            var limits: [Object] = shaped(usage[Key.limits])
            for (k, limit) in u.limits.enumerated() {
                if let f = figures.first(where: { $0.label == limit.label }) { limits[k][Key.left] = f.left }
            }
            usage[Key.limits] = limits
            accounts[j][Key.usage] = usage
        }
        providers[i][Key.accounts] = accounts
    }
    root[Key.providers] = providers
    return try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
}

/// A member of the JSON `JSONEncoder` just wrote for a snapshot, in the shape
/// its type encodes to.
func shaped<T>(_ value: Any?) -> T {
    guard let v = value as? T else { preconditionFailure("a snapshot encodes as nested objects and arrays") }
    return v
}

/// Writes `line` to stderr.
func say(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Writes `line` to stderr and exits with `code`.
func quit(_ line: String, _ code: Int32) -> Never {
    say(line)
    exit(code)
}

guard let command = Command(Array(CommandLine.arguments.dropFirst())) else { quit(synopsis, EX_USAGE) }
do {
    let paths = try Paths(env: ProcessInfo.processInfo.environment, username: NSUserName())
    let store = try Store(paths: paths)
    let reader = StatusReader(paths: paths, store: store)
    let switcher = Switcher(paths: paths, store: store, http: URLSessionClient(), clock: Date.init, turnWait: turnWait)
    switch command {
    case .status:
        FileHandle.standardOutput.write(try json(reader.read()) + Data("\n".utf8))
    case .usage(let p):
        let report = await switcher.probeAll(p)
        let errors = [report.saveBackError, report.providerError].compactMap { $0 }
        errors.forEach(say)
        if !errors.isEmpty { exit(EXIT_FAILURE) }
    case .use(let p, let n):
        try await switcher.use(p, n)
    }
} catch {
    quit((error as? KibaError)?.reason ?? String(describing: error), EXIT_FAILURE)
}
