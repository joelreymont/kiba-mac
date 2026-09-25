import Foundation

/// Opens a login script where the user can answer it.
public protocol TerminalLauncher: Sendable {
    func open(_ script: URL) throws
}

/// The Keychain as `add` sees it: the generic-password item of a service.
public protocol Keychain: Sendable {
    func item(_ service: String) -> SecretStore
}

/// Runs a provider's own login in Terminal against a throwaway home and saves
/// what it produced (kiba `add`). The live login is never read by the login
/// command and never revoked: the throwaway home keeps Codex away from it, and
/// a Claude login that overwrites the live Keychain item, as only an old CLI
/// does, gets it written back whatever the outcome. The old bytes wait in the
/// store until they are back, so an add the app does not live to finish is
/// undone at the next start.
public actor LoginRunner {
    let paths: Paths
    let switcher: Switcher
    let terminal: any TerminalLauncher
    let keychain: any Keychain
    /// The `PATH` searched for `claude` and `codex`.
    let searchPath: String
    /// Providers whose login is in flight. Every login of a provider uses the
    /// same throwaway home, so a second one would wreck the first.
    var running: Set<Provider> = []

    /// Undoes an unfinished add (`recover`) before anything reads the live login.
    public init(
        paths: Paths, switcher: Switcher, terminal: any TerminalLauncher, keychain: any Keychain, searchPath: String
    ) throws {
        self.paths = paths
        self.switcher = switcher
        self.terminal = terminal
        self.keychain = keychain
        self.searchPath = searchPath
        try recover()
    }

    /// Logs in, saves the new login, probes it, and removes the throwaway
    /// home, all in `p`'s turn, so no switch or probe of `p` runs between the
    /// snapshot of the live login and the probe of the new one. `differs`
    /// when `email` was given and another account signed in; `loginRunning`
    /// while another add for `p` waits on its login. A failure removes the
    /// throwaway home, except where the login may still run or the import
    /// failed: the login's source goes only once the import has committed.
    /// A Claude add first undoes the one a failed stop left, as `init` does,
    /// so the record of the live item is put back before a new one replaces it.
    public func add(_ p: Provider, expected email: String?) async throws -> AddResult {
        guard running.insert(p).inserted else { throw KibaError.loginRunning(p) }
        defer { running.remove(p) }
        guard let cli = Subprocess.find(Self.command(p), path: searchPath) else { throw KibaError.noCLI(Self.command(p)) }
        let ops = switcher.ops(p)
        await ops.enter()
        defer { ops.leave() }
        if p == .claude { try recover() }
        let root = paths.loginRoot(p)
        let snap = try Self.removing(root) { try prepare(p, cli: cli, email: email, root: root) }
        let ended = try await run(root)
        let found = try Self.removing(root) { try settle(snap, ended, root: root) }
        let saved = try switcher.importInTurn(p, root: root, claudeCreds: found.creds)
        try found.item?.remove()
        try PrivateFS.removeTree(root)
        try await switcher.probeInTurn(p, saved, live: false)
        return AddResult(saved: saved, expected: email, differs: email.map { saved.email != $0 } ?? false)
    }

    /// Makes the throwaway home afresh with this run's nonce and the login
    /// script. For Claude, snapshots the login's own item and the live one,
    /// whose bytes stay in the store from before the launch until they are
    /// back; nil for Codex, whose login cannot reach the live one.
    func prepare(_ p: Provider, cli: URL, email: String?, root: URL) throws -> Snapshot? {
        try PrivateFS.removeTree(root)
        let home = p == .claude ? paths.claudeConfigDir(root: root) : paths.codexHome(root: root)
        try PrivateFS.ensurePrivateDir(home)
        let nonce = UUID().uuidString
        try PrivateFS.writePrivate(Data(nonce.utf8), to: Self.file(root, Name.nonce))
        let script = Self.file(root, Name.script)
        let text = Self.script(p, cli: cli, email: email, home: home, root: root, nonce: nonce)
        try PrivateFS.writePrivate(Data(text.utf8), to: script)
        guard chmod(script.path, Self.scriptMode) == 0 else { throw KibaError.io(PrivateFS.failure("chmod", script.path)) }
        guard p == .claude else { return nil }
        let snap = Snapshot(before: try loginItem.read(), old: LiveItem(bytes: try liveItem.read()))
        try switcher.store.write { try $0.noteAdding(.claude, snap.old) }
        return snap
    }

    /// Once the login has ended: puts the live Claude item back when the
    /// login wrote it, throws why the login failed, then finds what it
    /// produced.
    func settle(_ snap: Snapshot?, _ ended: Result<Int32, any Error>, root: URL) throws -> Found {
        guard let snap else {
            try Self.check(ended)
            return Found(creds: nil, item: nil)
        }
        let own = try filed(root: root, before: snap.before)
        let written = try restore(snap.old, filed: own != nil)
        try Self.check(ended)
        if let own { return own }
        guard let written else { throw KibaError.loginProducedNothing(.claude) }
        return Found(creds: written, item: nil)
    }

    /// Opens the login script in Terminal and waits for its exit status. A
    /// wait that ends without one (Terminal did not open it, the task was
    /// cancelled, the status is unreadable) stops the login first, so it
    /// cannot touch anything after the cleanup that follows, and is the
    /// failure returned. Throws only when that stop fails: the login may
    /// still run, so its home and the live item's record stay for the next
    /// start or the next Claude add.
    func run(_ root: URL) async throws -> Result<Int32, any Error> {
        do {
            try terminal.open(Self.file(root, Name.script))
            return .success(try await Self.exitStatus(Self.file(root, Name.exit), dir: root))
        } catch {
            try Self.stop(root)
            return .failure(error)
        }
    }

    /// Why the login ended without a status, or `loginFailed` for a status
    /// other than 0.
    static func check(_ ended: Result<Int32, any Error>) throws {
        let status = try ended.get()
        guard status == 0 else { throw KibaError.loginFailed(status) }
    }

    /// `body`'s result; when it throws, the throwaway home `root` goes first.
    static func removing<T>(_ root: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            try PrivateFS.removeTree(root)
            throw error
        }
    }

    /// Undoes an add the app did not live to finish, found by its record in
    /// the store: stops its login if that still runs, writes the live item
    /// back unless the login filed credentials in its own home (its item
    /// counts as absent before), and removes the throwaway home.
    nonisolated func recover() throws {
        guard let old = try switcher.store.adding(.claude) else { return }
        let root = paths.loginRoot(.claude)
        try Self.stop(root)
        try restore(old, filed: try filed(root: root, before: nil) != nil)
        try PrivateFS.removeTree(root)
    }

    /// Writes the live Claude item back as `old` holds it (removes it when
    /// there was none) when the login wrote it, then drops the store's record
    /// of it. The login wrote it only when it `filed` its credentials nowhere
    /// in its own home, as an old CLI did; Claude Code 2.1.282 files them
    /// under `paths.loginService`, so a change beside them is its own refresh
    /// of the live login, which stays. Returns the bytes the login left there.
    @discardableResult
    nonisolated func restore(_ old: LiveItem, filed: Bool) throws -> Data? {
        let now = try liveItem.read()
        let wrote = !filed && now != old.bytes
        if wrote {
            if let bytes = old.bytes { try liveItem.write(bytes) } else { try liveItem.remove() }
        }
        try switcher.store.write { try $0.clearAdding(.claude) }
        return wrote ? now : nil
    }

    /// The live Claude Keychain item.
    nonisolated var liveItem: any SecretStore { keychain.item(paths.keychainService) }

    /// The Keychain item a Claude login in the throwaway home writes.
    nonisolated var loginItem: any SecretStore { keychain.item(paths.loginService) }

    /// The Claude items before the login: its own (`before`) and the live
    /// one (`old`, in the store until it is back).
    struct Snapshot {
        let before: Data?
        let old: LiveItem
    }

    /// What a login produced: the Claude credentials, and the login's own
    /// Keychain item they came from, which goes once the import commits.
    struct Found {
        var creds: Data?
        var item: (any SecretStore)?
    }

    /// Where a Claude login filed its credentials in its own home, first hit
    /// wins: the config dir's `.credentials.json`; the login's own Keychain
    /// item when it holds other bytes than `before`, since the login home's
    /// fixed path always names the same item and an earlier add may have left
    /// it behind. Nil when it filed none. Items of other config dirs are
    /// never read: they refresh on their own.
    nonisolated func filed(root: URL, before: Data?) throws -> Found? {
        if let file = try PrivateFS.read(paths.claudeCredsFile(root: root)) { return Found(creds: file, item: nil) }
        if let bytes = try loginItem.read(), bytes != before { return Found(creds: bytes, item: loginItem) }
        return nil
    }

    /// The login script Terminal runs: files its pid, exports the throwaway
    /// home, asks the user to sign in first, runs the CLI found on `PATH`,
    /// and reports its exit status by renaming a file into place. A closed
    /// window or an interrupt reports too, so the wait always ends. It first
    /// exits unless the root's nonce file holds its own `nonce`, so a script
    /// an earlier add wrote, started late by Terminal, never runs in a root
    /// made again since. The pid goes in by hard link, which fails when
    /// `stop` has claimed the name first; the script then exits without
    /// running the login.
    static func script(_ p: Provider, cli: URL, email: String?, home: URL, root: URL, nonce: String) -> String {
        let nonceFile = quoted(file(root, Name.nonce).path)
        let pidTmp = quoted(file(root, Name.pidTmp).path)
        let pid = quoted(file(root, Name.pid).path)
        let tmp = quoted(file(root, Name.exitTmp).path)
        let exit = quoted(file(root, Name.exit).path)
        let args = p == .claude ? ["auth", "login"] + (email.map { ["--email", $0] } ?? []) : ["login"]
        let command = ([cli.path] + args).map(quoted).joined(separator: " ")
        let traps = Signal.all.map { "trap 'report \($0.status); exit \($0.status)' \($0.name)" }
        return ([
            "#!/bin/sh",
            "[ \"$(cat \(nonceFile) 2>/dev/null)\" = \(quoted(nonce)) ] || exit \(staleStatus)",
            "printf '%s' \"$$\" > \(pidTmp) && ln \(pidTmp) \(pid) || exit \(staleStatus)",
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

    static func file(_ root: URL, _ name: String) -> URL {
        root.appending(component: name, directoryHint: .notDirectory)
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
        throw KibaError.io("login wait cancelled before \(file.path) appeared")
    }

    /// Ends the login the script in `root` started, if it still runs: SIGTERM
    /// to the script's process group ends the CLI and makes the script report
    /// as for a closed window; SIGKILL follows past `stopGrace`. A script that
    /// has not filed its pid yet never will, since the name is claimed here.
    static func stop(_ root: URL) throws {
        guard let pid = try claimPid(root) else { return }
        let script = file(root, Name.script)
        guard runs(pid, script) else { return }
        let group = getpgid(pid)
        guard group >= 0 else {
            guard errno == ESRCH else { throw KibaError.io(PrivateFS.failure("getpgid", script.path)) }
            return
        }
        try signal(group, SIGTERM, script)
        let end = DispatchTime.now() + stopGrace
        while runs(pid, script) {
            guard DispatchTime.now() < end else { return try signal(group, SIGKILL, script) }
            Thread.sleep(forTimeInterval: stopTick)
        }
    }

    /// The pid the login script filed as it started; nil when it has not, and
    /// now cannot: the name is taken here first (an empty file), so its link
    /// fails. Nil too when `root` is gone, as nothing can run from it.
    static func claimPid(_ root: URL) throws -> pid_t? {
        let url = file(root, Name.pid)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, PrivateFS.fileMode)
        if fd >= 0 {
            close(fd)
            return nil
        }
        switch errno {
        case ENOENT: return nil
        case EEXIST: break
        default: throw KibaError.io(PrivateFS.failure("open", url.path))
        }
        guard let data = try PrivateFS.read(url), !data.isEmpty else { return nil }
        guard let pid = pid_t(String(decoding: data, as: UTF8.self)) else {
            throw KibaError.io("login pid is not a number: \(url.path)")
        }
        return pid
    }

    /// Whether `pid` still runs `script`: one of its arguments names it. A pid
    /// the system has handed to another process names something else, and an
    /// ended process has no arguments left to read.
    static func runs(_ pid: pid_t, _ script: URL) -> Bool {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0, size > argcSize else { return false }
        // argc, then the executable path and each argument, NUL-terminated.
        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        let words = buf[argcSize..<size].split(separator: 0)
        return words.dropFirst().prefix(argc).contains { $0.elementsEqual(script.path.utf8) }
    }

    static func signal(_ group: pid_t, _ sig: Int32, _ script: URL) throws {
        guard kill(-group, sig) == 0 || errno == ESRCH else {
            throw KibaError.io(PrivateFS.failure("kill", "the process group of \(script.path)"))
        }
    }

    static let scriptMode: mode_t = 0o700
    static let pollInterval = DispatchTimeInterval.seconds(1)
    /// How long a stopped login gets to end on SIGTERM.
    static let stopGrace = DispatchTimeInterval.seconds(5)
    /// How often a stopped login is checked for its end.
    static let stopTick: TimeInterval = 0.05
    /// Exit status of a script that starts in a root not its own, or after
    /// `stop` claimed its pid name.
    static let staleStatus = 1
    static let argcSize = MemoryLayout<Int32>.size

    private enum Name {
        static let script = "login.command"
        static let nonce = "nonce"
        static let pid = "pid"
        static let pidTmp = "pid.tmp"
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

/// The login Keychain through `/usr/bin/security`: items as `KeychainItem`s
/// under the user's account.
public struct KeychainTool: Keychain {
    public let account: String

    public init(account: String) {
        self.account = account
    }

    public func item(_ service: String) -> SecretStore {
        KeychainItem(service: service, account: account)
    }
}
