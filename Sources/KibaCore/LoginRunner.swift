import Foundation

/// Opens a login script where the user can answer it.
public protocol TerminalLauncher: Sendable {
    func open(_ script: URL) throws
}

/// The Keychain as `add` sees it: the generic-password services under a
/// prefix, and the item behind one of them.
public protocol KeychainLister: Sendable {
    func services(prefix: String) throws -> Set<String>
    func item(_ service: String) -> SecretStore
}

/// Runs a provider's own login in Terminal against a throwaway home and saves
/// what it produced (kiba `add`). The live login is never read by the login
/// command and never revoked: the throwaway home keeps Codex away from it, and
/// a Claude login that overwrites the live Keychain item gets it written back.
public actor LoginRunner {
    let paths: Paths
    let switcher: Switcher
    let terminal: any TerminalLauncher
    let lister: any KeychainLister
    /// The `PATH` searched for `claude` and `codex`.
    let searchPath: String

    public init(
        paths: Paths, switcher: Switcher, terminal: any TerminalLauncher, lister: any KeychainLister, searchPath: String
    ) {
        self.paths = paths
        self.switcher = switcher
        self.terminal = terminal
        self.lister = lister
        self.searchPath = searchPath
    }

    /// Logs in, saves the new login, probes it, and removes the throwaway
    /// home whatever happened. `differs` when `email` was given and another
    /// account signed in.
    public func add(_ p: Provider, expected email: String?) async throws -> AddResult {
        guard let cli = Subprocess.find(Self.command(p), path: searchPath) else { throw KibaError.noCLI(Self.command(p)) }
        let root = paths.loginRoot(p)
        try PrivateFS.removeTree(root)
        let saved: SlotName
        do {
            saved = try await login(p, cli: cli, email: email, root: root)
        } catch {
            try PrivateFS.removeTree(root)
            throw error
        }
        try PrivateFS.removeTree(root)
        return AddResult(saved: saved, expected: email, differs: email.map { saved.email != $0 } ?? false)
    }

    func login(_ p: Provider, cli: URL, email: String?, root: URL) async throws -> SlotName {
        let home = p == .claude ? paths.claudeConfigDir(root: root) : paths.codexHome(root: root)
        try PrivateFS.ensurePrivateDir(home)
        let live = lister.item(paths.keychainService)
        var before: Set<String> = []
        var liveBytes: Data?
        if p == .claude {
            before = try lister.services(prefix: paths.keychainService)
            liveBytes = try live.read()
        }
        let script = root.appending(component: Name.script, directoryHint: .notDirectory)
        try PrivateFS.writePrivate(Data(Self.script(p, cli: cli, email: email, home: home, root: root).utf8), to: script)
        guard chmod(script.path, Self.scriptMode) == 0 else { throw KibaError.io(PrivateFS.failure("chmod", script.path)) }
        try terminal.open(script)
        let status = try await Self.exitStatus(root.appending(component: Name.exit, directoryHint: .notDirectory), dir: root)
        guard status == 0 else { throw KibaError.loginFailed(status) }
        let creds = p == .claude ? try claudeCreds(root: root, before: before, live: live, liveBytes: liveBytes) : nil
        let saved = try switcher.importLogin(p, root: root, claudeCreds: creds)
        try await switcher.probe(p, saved, live: false)
        return saved
    }

    /// Where a Claude login put its credentials, first hit wins: the config
    /// dir's `.credentials.json`; a Keychain item that did not exist before
    /// (read, then deleted); the live Keychain item, when the login overwrote
    /// it (the new bytes are kept and the old ones written back).
    func claudeCreds(root: URL, before: Set<String>, live: SecretStore, liveBytes: Data?) throws -> Data {
        if let file = try PrivateFS.read(paths.claudeCredsFile(root: root)) { return file }
        for service in try lister.services(prefix: paths.keychainService).subtracting(before).sorted() {
            let item = lister.item(service)
            guard let bytes = try item.read() else { continue }
            try item.remove()
            return bytes
        }
        if let now = try live.read(), now != liveBytes {
            if let liveBytes { try live.write(liveBytes) } else { try live.remove() }
            return now
        }
        throw KibaError.loginProducedNothing(.claude)
    }

    /// The login script Terminal runs: exports the throwaway home, asks the
    /// user to sign in first, runs the CLI found on `PATH`, and reports its
    /// exit status by renaming a file into place. A closed window or an
    /// interrupt reports too, so the wait always ends.
    static func script(_ p: Provider, cli: URL, email: String?, home: URL, root: URL) -> String {
        let tmp = quoted(root.appending(component: Name.exitTmp, directoryHint: .notDirectory).path)
        let exit = quoted(root.appending(component: Name.exit, directoryHint: .notDirectory).path)
        let args = p == .claude ? ["auth", "login"] + (email.map { ["--email", $0] } ?? []) : ["login"]
        let command = ([cli.path] + args).map(quoted).joined(separator: " ")
        let traps = Signal.all.map { "trap 'report \($0.status); exit \($0.status)' \($0.name)" }
        return ([
            "#!/bin/sh",
            "export \(p.homeVar)=\(quoted(home.path))",
            "report() { printf '%s' \"$1\" > \(tmp) && mv \(tmp) \(exit); }",
        ] + traps + [
            "printf 'Sign in to %s at %s in your browser, then press Enter to continue: ' \(quoted(email ?? Name.anyone)) \(quoted(p.site))",
            "read -r _",
            command,
            "rc=$?",
            "trap - \(Signal.all.map(\.name).joined(separator: " "))",
            "report \"$rc\"",
            "if [ \"$rc\" -ne 0 ]; then printf '\\nPress Enter to close\\n'; read -r _; fi",
            "exit \"$rc\"",
        ]).joined(separator: "\n") + "\n"
    }

    /// `s` as one single-quoted shell word.
    static func quoted(_ s: String) -> String {
        "'" + s.replacing("'", with: #"'\''"#) + "'"
    }

    static func command(_ p: Provider) -> String {
        switch p {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// Waits until the script's exit status file appears. A watch on `dir`
    /// wakes the wait as soon as the file is renamed in; a poll every second
    /// covers an event the watch missed.
    static func exitStatus(_ file: URL, dir: URL) async throws -> Int32 {
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { throw KibaError.io(PrivateFS.failure("open", dir.path)) }
        let (ticks, feed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = DispatchQueue(label: Name.queue)
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        watch.setEventHandler { feed.yield() }
        watch.setCancelHandler { close(fd) }
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now(), repeating: pollInterval)
        poll.setEventHandler { feed.yield() }
        watch.resume()
        poll.resume()
        defer {
            watch.cancel()
            poll.cancel()
            feed.finish()
        }
        for await _ in ticks {
            guard let data = try PrivateFS.read(file) else { continue }
            guard let status = Int32(String(decoding: data, as: UTF8.self)) else {
                throw KibaError.io("login exit status is not a number: \(file.path)")
            }
            return status
        }
        throw CancellationError()
    }

    static let scriptMode: mode_t = 0o700
    static let pollInterval = DispatchTimeInterval.seconds(1)

    private enum Name {
        static let script = "login.command"
        static let exit = "exit"
        static let exitTmp = "exit.tmp"
        static let anyone = "the account to add"
        static let queue = "kiba.login-wait"
    }

    /// Signals that end the script early, and the status each reports: 128
    /// plus the signal number, as shells report it.
    private enum Signal {
        static let all: [(name: String, status: Int32)] = [
            ("HUP", Subprocess.signalBase + SIGHUP),
            ("INT", Subprocess.signalBase + SIGINT),
            ("TERM", Subprocess.signalBase + SIGTERM),
        ]
    }
}

/// Opens a `.command` script in Terminal, which runs it in a new window.
public struct TerminalApp: TerminalLauncher {
    static let tool = URL(fileURLWithPath: "/usr/bin/open", isDirectory: false)
    static let name = "open"
    static let args = ["-a", "Terminal"]

    public init() {}

    public func open(_ script: URL) throws {
        let r = try Subprocess.run(Self.tool, Self.args + [script.path], stdin: nil, env: nil, setsid: false)
        guard r.status == 0 else { throw KibaError.tool(Self.name, r.status, String(decoding: r.stderr, as: UTF8.self)) }
    }
}

/// The login Keychain through `/usr/bin/security`: service names from
/// `dump-keychain` (attributes only, never secret data), items as
/// `KeychainItem`s under the user's account.
public struct KeychainTool: KeychainLister {
    public let account: String

    /// How `dump-keychain` prints a printable service attribute.
    static let serviceMark = #""svce"<blob>=""#
    static let quote = "\""

    public init(account: String) {
        self.account = account
    }

    public func services(prefix: String) throws -> Set<String> {
        let r = try Subprocess.run(KeychainItem.tool, ["dump-keychain"], stdin: nil, env: nil, setsid: false)
        guard r.status == 0 else { throw KeychainItem.failed(r) }
        return Self.services(in: r.stdout, prefix: prefix)
    }

    public func item(_ service: String) -> SecretStore {
        KeychainItem(service: service, account: account)
    }

    /// The printable service names in a dump that start with `prefix`. A name
    /// with unprintable bytes is dumped as hex and cannot start with a
    /// printable prefix, so it is passed over.
    static func services(in dump: Data, prefix: String) -> Set<String> {
        var out: Set<String> = []
        for line in String(decoding: dump, as: UTF8.self).split(separator: "\n") {
            let text = line.drop { $0 == " " }
            guard text.hasPrefix(serviceMark), text.hasSuffix(quote), text.count > serviceMark.count else { continue }
            let name = String(text.dropFirst(serviceMark.count).dropLast())
            if name.hasPrefix(prefix) { out.insert(name) }
        }
        return out
    }
}
