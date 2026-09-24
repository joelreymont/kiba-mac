import Foundation
import KibaCore
import Testing

@testable import KibaApp

// Every test runs in its own scratch world (HOME, CLAUDE_CONFIG_DIR, CODEX_HOME
// and PATH under /private/tmp), with stubbed HTTP and a frozen clock, and checks
// what the user would see: live files, store rows, snapshots and rows.

// MARK: - Switch

@Test func switchSavesBackAndInstalls() async throws {
    try await scratch { w in
        let (ax, bx) = (try slot("a@x"), try slot("b@x"))
        let (ay, by) = (try slot("a@y"), try slot("b@y"))
        let liveCreds = claudeCreds("xa2", plan: "max", expires: Fixed.now + Fixed.day)
        let credsB = claudeCreds("xb", plan: "pro", expires: Fixed.now + Fixed.day)
        let profA = profile("a@x", org: "org-a"), profB = profile("b@x", org: "org-b")
        try w.writeClaude(config: claudeConfig(profA), creds: liveCreds)
        try w.seed(.claude, ax, Identity(email: "a@x", plan: "max", org: "org-a"),
                   login: claudeCreds("xa1", plan: "max", expires: Fixed.now), profile: profA)
        try w.seed(.claude, bx, Identity(email: "b@x", plan: "pro", org: "org-b"), login: credsB, profile: profB)

        let liveAuth = codexAuth("a@y", plan: "plus", account: "acct-a", tag: "ya2")
        let authB = codexAuth("b@y", plan: "pro", account: "acct-b", tag: "yb")
        try w.writeCodex(liveAuth)
        try w.seed(.codex, ay, Identity(email: "a@y", plan: "plus", org: "acct-a"),
                   login: codexAuth("a@y", plan: "plus", account: "acct-a", tag: "ya1"), profile: nil)
        try w.seed(.codex, by, Identity(email: "b@y", plan: "pro", org: "acct-b"), login: authB, profile: nil)

        let http = StubHTTP([answer(Status.ok, claudeUsage(session: 30, week: 60)),
                             answer(Status.ok, claudeUsage(session: 10, week: 20)),
                             answer(Status.ok, codexUsage(session: 20, week: 45)),
                             answer(Status.ok, codexUsage(session: 15, week: 25))])
        let sw = w.switcher(http)
        try await sw.use(.claude, bx)
        try await sw.use(.codex, by)

        let savedA = try w.store.fetch(.claude, ax)
        #expect(savedA?.login == liveCreds)
        #expect(savedA?.profile == profA)
        #expect(w.read(w.paths.claudeCredsFile(root: nil)) == credsB)
        #expect(w.read(w.paths.claudeConfigFile(root: nil)) == claudeConfig(profB))
        #expect(try w.store.installed(.claude) == bx)
        #expect(try w.store.fetch(.codex, ay)?.login == liveAuth)
        #expect(w.read(w.paths.codexAuthFile(root: nil)) == authB)
        #expect(try w.store.installed(.codex) == by)

        #expect(http.requests.map(\.url.absoluteString) ==
                [Endpoint.claudeUsage, Endpoint.claudeUsage, Endpoint.codexUsage, Endpoint.codexUsage])
        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-xb", "Bearer at-xa2", "Bearer at-yb", "Bearer at-ya2"])
        #expect(http.requests.map { $0.headers[Header.agent] } == ["kiba", "kiba", "codex-cli", "codex-cli"])

        let want = [
            ProviderStatus(provider: .claude, live: LiveLogin(email: "b@x", plan: "pro"), accounts: [
                Account(name: ax, plan: "max", active: false, usage: probed(windows(session: 10, week: 20))),
                Account(name: bx, plan: "pro", active: true, usage: probed(windows(session: 30, week: 60))),
            ], error: nil),
            ProviderStatus(provider: .codex, live: LiveLogin(email: "b@y", plan: "pro"), accounts: [
                Account(name: ay, plan: "plus", active: false, usage: probed(windows(session: 15, week: 25))),
                Account(name: by, plan: "pro", active: true, usage: probed(windows(session: 20, week: 45))),
            ], error: nil),
        ]
        #expect(StatusReader(paths: w.paths, store: w.store).read().providers == want)
    }
}

@Test func switchRefreshesTheExpiredLoginItLeaves() async throws {
    try await scratch { w in
        let (ax, bx) = (try slot("a@x"), try slot("b@x"))
        let credsA = claudeCreds("xa", plan: "max", expires: Fixed.now - Fixed.hour)
        let credsB = claudeCreds("xb", plan: "pro", expires: Fixed.now + Fixed.day)
        let profA = profile("a@x", org: "org-a"), profB = profile("b@x", org: "org-b")
        let expired = UsageRecord(
            fetchedAt: Fixed.now, state: .expired, note: "access token expired; Claude Code refreshes it on its next run",
            limits: [])
        try w.writeClaude(config: claudeConfig(profA), creds: credsA)
        try w.seed(.claude, ax, Identity(email: "a@x", plan: "max", org: "org-a"), login: credsA, profile: profA,
                   usage: expired)
        try w.seed(.claude, bx, Identity(email: "b@x", plan: "pro", org: "org-b"), login: credsB, profile: profB)
        let http = StubHTTP([
            answer(Status.ok, claudeUsage(session: 30, week: 60)),
            answer(Status.ok, #"{"access_token":"at-xa2","refresh_token":"rt-xa2","expires_in":\#(Fixed.tokenLife)}"#),
            answer(Status.ok, claudeUsage(session: 10, week: 20)),
        ])

        try await w.switcher(http).use(.claude, bx)

        #expect(http.requests.map(\.url.absoluteString) == [Endpoint.claudeUsage, Endpoint.claudeToken, Endpoint.claudeUsage])
        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-xb", nil, "Bearer at-xa2"])
        #expect(try w.store.fetch(.claude, ax)?.login == claudeCreds("xa2", plan: "max", expires: Fixed.now + Fixed.tokenLife))
        #expect(w.read(w.paths.claudeCredsFile(root: nil)) == credsB)
        let claude = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .claude }
        let accounts = try #require(claude).accounts
        #expect(accounts == [
            Account(name: ax, plan: "max", active: false, usage: probed(windows(session: 10, week: 20))),
            Account(name: bx, plan: "pro", active: true, usage: probed(windows(session: 30, week: 60))),
        ])
        #expect(accounts.map { Rows.dead($0.usage, active: $0.active) } == [false, false])
    }
}

@Test func failedCredsWriteKeepsLiveLogin() async throws {
    try await scratch { w in
        let (ax, bx) = (try slot("a@x"), try slot("b@x"))
        let profA = profile("a@x", org: "org-a"), profB = profile("b@x", org: "org-b")
        let credsA = claudeCreds("xa2", plan: "max", expires: Fixed.now + Fixed.day)
        let credsB = claudeCreds("xb", plan: "pro", expires: Fixed.now + Fixed.day)
        try w.seed(.claude, ax, Identity(email: "a@x", plan: "max", org: "org-a"), login: credsA, profile: profA)
        try w.seed(.claude, bx, Identity(email: "b@x", plan: "pro", org: "org-b"), login: credsB, profile: profB)
        try w.store.write { try $0.noteInstalled(.claude, ax) }
        // The live credentials link into a directory no file can be created in:
        // they read, but replacing them fails after the config is written.
        let locked = w.dir.appending(component: "locked")
        let creds = locked.appending(component: "creds.json")
        let config = w.paths.claudeConfigFile(root: nil)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try credsA.write(to: creds)
        try claudeConfig(profA).write(to: config)
        try FileManager.default.createSymbolicLink(at: w.paths.claudeCredsFile(root: nil), withDestinationURL: creds)
        try FileManager.default.setAttributes([.posixPermissions: Fixed.lockedMode], ofItemAtPath: locked.path)
        defer { chmod(locked.path, mode_t(Fixed.openMode)) }
        let sw = w.switcher(StubHTTP([]))

        await #expect(throws: KibaError.self) { try await sw.use(.claude, bx) }
        #expect(w.read(config) == claudeConfig(profA))
        #expect(w.read(creds) == credsA)
        #expect(try w.store.installed(.claude) == ax)

        // Claude Code refreshes a@x's tokens; saving files them under a@x.
        let refreshed = claudeCreds("xa3", plan: "max", expires: Fixed.now + Fixed.day)
        try refreshed.write(to: creds)
        #expect(try sw.save(.claude) == ax)
        #expect(try w.store.fetch(.claude, ax)?.login == refreshed)
        #expect(try w.store.fetch(.claude, bx)?.login == credsB)

        // A crash between the two live writes of an install of b@x, then a
        // refresh: the tokens match no saved row, and still nothing saves them.
        try w.store.write { try $0.notePending(.claude, bx) }
        try claudeConfig(profB).write(to: config)
        try claudeCreds("xa4", plan: "max", expires: Fixed.now + Fixed.day).write(to: creds)
        #expect(throws: KibaError.mixed) { try sw.save(.claude) }
        #expect(try w.store.list(.claude).map(\.login) == [refreshed, credsB])
    }
}

// MARK: - Probe

@Test func probeRefreshesSavedClaudeLoginsOnly() async throws {
    try await scratch { w in
        let liveCreds = claudeCreds("a", plan: "max", expires: Fixed.now - Fixed.hour)
        try w.writeClaude(config: claudeConfig(profile("a@x", org: "org-a")), creds: liveCreds)
        try w.seed(.claude, try slot("b@x"), Identity(email: "b@x", plan: "pro", org: "org-b"),
                   login: claudeCreds("b", plan: "pro", expires: Fixed.now - Fixed.hour), profile: profile("b@x", org: "org-b"))
        try w.seed(.claude, try slot("c@x"), Identity(email: "c@x", plan: "pro", org: "org-c"),
                   login: claudeCreds("c", plan: "pro", expires: Fixed.now + Fixed.day), profile: profile("c@x", org: "org-c"))
        let http = StubHTTP([
            answer(Status.ok, #"{"access_token":"at-b2","refresh_token":"rt-b2","expires_in":\#(Fixed.tokenLife)}"#),
            answer(Status.ok, claudeUsage(session: 30, week: 60)),
            answer(Status.unauthorized, "{}"),
        ])

        let report = await w.switcher(http).probeAll(.claude)

        #expect(report.saveBackError == nil)
        #expect(report.providerError == nil)
        #expect(http.requests.map(\.method) == ["POST", "GET", "GET"])
        #expect(http.requests.map(\.url.absoluteString) == [Endpoint.claudeToken, Endpoint.claudeUsage, Endpoint.claudeUsage])
        #expect(http.requests.map { $0.headers[Header.auth] } == [nil, "Bearer at-b2", "Bearer at-c"])
        #expect(text(http.requests[0].body ?? Data()).contains(#""refresh_token":"rt-b""#))
        let rows = try w.store.list(.claude)
        try #require(rows.map(\.name.raw) == ["a@x", "b@x", "c@x"])
        #expect(rows[0].login == liveCreds)
        #expect(rows[0].usage == UsageRecord(
            fetchedAt: Fixed.now, state: .expired, note: "access token expired; Claude Code refreshes it on its next run",
            limits: []))
        #expect(rows[1].login == claudeCreds("b2", plan: "pro", expires: Fixed.now + Fixed.tokenLife))
        #expect(rows[1].usage == probed(windows(session: 30, week: 60)))
        #expect(rows[2].usage?.state == .expired)
        #expect(Rows.state(rows[2].usage, active: false) == .dead)
        #expect(w.read(w.paths.claudeCredsFile(root: nil)) == liveCreds)
    }
}

@Test func probeRemovesRevokedSavedCodexLogin() async throws {
    try await scratch { w in
        let liveAuth = codexAuth("live@y", plan: "plus", account: "acct-l", tag: "l")
        try w.writeCodex(liveAuth)
        try w.seed(.codex, try slot("gone@y"), Identity(email: "gone@y", plan: "plus", org: "acct-g"),
                   login: codexAuth("gone@y", plan: "plus", account: "acct-g", tag: "g"), profile: nil)
        let revoked = #"{"error":{"code":"token_revoked","message":"Token revoked"}}"#
        let http = StubHTTP([
            answer(Status.unauthorized, revoked),
            answer(Status.unauthorized, #"{"error":"invalid_grant"}"#),
            answer(Status.unauthorized, revoked),
        ])

        let report = await w.switcher(http).probeAll(.codex)

        #expect(report.accounts.map(\.0.raw) == ["gone@y", "live@y"])
        #expect(report.accounts.first?.1 == .revoked(note: "login revoked by a later `codex login`"))
        #expect(http.requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-g", nil, "Bearer at-l"])
        let rows = try w.store.list(.codex)
        #expect(rows.map(\.name.raw) == ["live@y"])
        #expect(rows.first?.usage?.state == .expired)
        #expect(rows.first?.login == liveAuth)
        #expect(w.read(w.paths.codexAuthFile(root: nil)) == liveAuth)
    }
}

// MARK: - Rows

@Test func rowsSortRoomTightUsedUpThenDead() async throws {
    try await scratch { w in
        for name in ["b@x", "c@x", "d@x"] {
            try w.seed(.claude, try slot(name), Identity(email: name, plan: "pro", org: "org-\(name)"),
                       login: claudeCreds(name, plan: "pro", expires: Fixed.now + Fixed.day),
                       profile: profile(name, org: "org-\(name)"))
        }
        let http = StubHTTP([
            answer(Status.ok, claudeUsage(session: 100, week: 60)),
            answer(Status.ok, claudeUsage(session: 70, week: 30)),
            answer(Status.ok, claudeUsage(session: 10, week: 20, opus: 40)),
        ])
        let report = await w.switcher(http).probeAll(.claude)
        #expect(report.providerError == nil)
        try w.seed(.claude, try slot("a@x"), Identity(email: "a@x", plan: "pro", org: "org-a"),
                   login: claudeCreds("a", plan: "pro", expires: Fixed.now + Fixed.day), profile: profile("a@x", org: "org-a"),
                   usage: UsageRecord(fetchedAt: Fixed.now, state: .revoked, note: "login revoked", limits: []))

        let claude = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .claude }
        let accounts = try #require(claude).accounts
        try #require(accounts.map(\.name.raw) == ["a@x", "b@x", "c@x", "d@x"])
        #expect(accounts.map { Rows.state($0.usage, active: $0.active) } == [.dead, .blocked, .tight, .ok])
        #expect(Rows.sorted(accounts).map(\.name.raw) == ["d@x", "c@x", "b@x", "a@x"])
        #expect(Rows.figures(accounts[3].usage) == [
            Figure(label: "Session (5-hour)", left: 90), Figure(label: "Weekly (7-day)", left: 80),
            Figure(label: "Opus Weekly", left: 60),
        ])
    }
}

// MARK: - Add account

@Test func addCodexSavesNewLoginAndKeepsLive() async throws {
    try await scratch { w in
        let liveAuth = codexAuth("live@y", plan: "plus", account: "acct-l", tag: "l")
        try w.writeCodex(liveAuth)
        let newAuth = codexAuth("new@y", plan: "pro", account: "acct-n", tag: "n")
        try w.fakeCLI("codex", "printf '%s' '\(text(newAuth))' > \"$CODEX_HOME/auth.json\"")
        let http = StubHTTP([answer(Status.ok, codexUsage(session: 20, week: 45))])

        let result = try await w.runner(http, keychain: FakeKeychain(items: [:])).add(.codex, expected: nil)

        let saved = try slot("new@y")
        #expect(result == AddResult(saved: saved, expected: nil, differs: false))
        let row = try w.store.fetch(.codex, saved)
        #expect(row?.login == newAuth)
        #expect(row?.identity == Identity(email: "new@y", plan: "pro", org: "acct-n"))
        #expect(row?.usage == probed(windows(session: 20, week: 45)))
        #expect(try w.store.list(.codex).map(\.name.raw) == ["new@y"])
        #expect(w.read(w.paths.codexAuthFile(root: nil)) == liveAuth)
        #expect(!FileManager.default.fileExists(atPath: w.paths.loginRoot(.codex).path))
    }
}

@Test func addClaudeFromFileAndFromKeychain() async throws {
    try await scratch { w in
        let liveCreds = claudeCreds("live", plan: "max", expires: Fixed.now + Fixed.day)
        let keychain = FakeKeychain(items: [w.paths.keychainService: MemorySecret(liveCreds)])
        let http = StubHTTP([answer(Status.ok, claudeUsage(session: 30, week: 60)),
                             answer(Status.ok, claudeUsage(session: 30, week: 60))])

        let otherCreds = claudeCreds("o", plan: "pro", expires: Fixed.now + Fixed.day)
        let otherProfile = profile("other@y", org: "org-o")
        try w.fakeCLI("claude", """
            printf '%s' '\(text(otherCreds))' > "$CLAUDE_CONFIG_DIR/.credentials.json"
            printf '%s' '\(text(claudeConfig(otherProfile)))' > "$CLAUDE_CONFIG_DIR/.claude.json"
            """)
        let other = try await w.runner(http, keychain: keychain).add(.claude, expected: "x@y")
        #expect(other == AddResult(saved: try slot("other@y"), expected: "x@y", differs: true))
        let otherRow = try w.store.fetch(.claude, try slot("other@y"))
        #expect(otherRow?.login == otherCreds)
        #expect(otherRow?.profile == otherProfile)

        // A login that writes the live Keychain item instead of a file.
        let newCreds = claudeCreds("k", plan: "pro", expires: Fixed.now + Fixed.day)
        let live = keychain.item(w.paths.keychainService)
        try w.fakeCLI("claude", """
            printf '%s' '\(text(claudeConfig(profile("k@y", org: "org-k"))))' > "$CLAUDE_CONFIG_DIR/.claude.json"
            """)
        let runner = w.runner(http, keychain: keychain) { try live.write(newCreds) }
        let added = try await runner.add(.claude, expected: "k@y")
        #expect(added == AddResult(saved: try slot("k@y"), expected: "k@y", differs: false))
        #expect(try w.store.fetch(.claude, try slot("k@y"))?.login == newCreds)
        #expect(try live.read() == liveCreds)
        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-o", "Bearer at-k"])
        #expect(!FileManager.default.fileExists(atPath: w.paths.loginRoot(.claude).path))
    }
}

@Test func addClaudeOverLeftoverKeychainItem() async throws {
    try await scratch { w in
        // An earlier add died before removing the login home's item.
        let liveCreds = claudeCreds("live", plan: "max", expires: Fixed.now + Fixed.day)
        let leftover = MemorySecret(claudeCreds("old", plan: "pro", expires: Fixed.now))
        let keychain = FakeKeychain(items: [
            w.paths.keychainService: MemorySecret(liveCreds), "\(w.paths.keychainService)-leftover": leftover,
        ])
        let newCreds = claudeCreds("n", plan: "pro", expires: Fixed.now + Fixed.day)
        try w.fakeCLI("claude", """
            printf '%s' '\(text(claudeConfig(profile("n@y", org: "org-n"))))' > "$CLAUDE_CONFIG_DIR/.claude.json"
            """)
        let http = StubHTTP([answer(Status.ok, claudeUsage(session: 30, week: 60))])
        let runner = w.runner(http, keychain: keychain) { try leftover.write(newCreds) }

        let added = try await runner.add(.claude, expected: "n@y")

        #expect(added == AddResult(saved: try slot("n@y"), expected: "n@y", differs: false))
        #expect(try w.store.fetch(.claude, try slot("n@y"))?.login == newCreds)
        #expect(try leftover.read() == nil)
        #expect(try keychain.item(w.paths.keychainService).read() == liveCreds)
        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-n"])
    }
}

@Test func addReportsMissingCLIAndFailedLogin() async throws {
    try await scratch { w in
        let runner = w.runner(StubHTTP([]), keychain: FakeKeychain(items: [:]))
        await #expect(throws: KibaError.noCLI("codex")) { try await runner.add(.codex, expected: nil) }
        try w.fakeCLI("codex", "exit 3")
        await #expect(throws: KibaError.loginFailed(3)) { try await runner.add(.codex, expected: nil) }
        #expect(try w.store.list(.codex).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: w.paths.loginRoot(.codex).path))
    }
}

// MARK: - Keychain

@Test func keychainItemRoundTrips() throws {
    try ensureKeychain()
    let item = KeychainItem(service: "\(Fixed.keychainPrefix)\(UUID().uuidString)", account: NSUserName())
    defer { #expect(throws: Never.self) { try item.remove() } }
    let small = claudeCreds("kc", plan: "pro", expires: Fixed.now)
    try item.write(small)
    #expect(try item.read() == small)
    // Too long for a `security -i` line: goes through argv.
    let big = Data(#"{"blob":"\#(String(repeating: "k", count: Fixed.bigSecret))"}"#.utf8)
    try item.write(big)
    #expect(try item.read() == big)
    try item.remove()
    #expect(try item.read() == nil)
}

// MARK: - Save and forget

@Test func saveNamesForgetRemovesMixedRefuses() async throws {
    try await scratch { w in
        let sw = w.switcher(StubHTTP([]))
        let first = codexAuth("s@z", plan: "plus", account: "org-1", tag: "s1")
        try w.writeCodex(first)
        #expect(try sw.save(.codex) == slot("s@z"))
        try w.writeCodex(codexAuth("s@z", plan: "team", account: "org-2", tag: "s2"))
        let second = try slot("s@z #2")
        #expect(try sw.save(.codex) == second)
        #expect(try w.store.list(.codex).map(\.name.raw) == ["s@z", "s@z #2"])
        #expect(try w.store.fetch(.codex, slot("s@z"))?.login == first)
        try sw.forget(.codex, second)
        #expect(try w.store.list(.codex).map(\.name.raw) == ["s@z"])
        #expect(throws: KibaError.noAccount(.codex, "s@z #2")) { try sw.forget(.codex, second) }

        // Claude Code swapped the account but the tokens are still m@x's.
        let m = try slot("m@x")
        let credsM = claudeCreds("m", plan: "pro", expires: Fixed.now + Fixed.day)
        try w.seed(.claude, m, Identity(email: "m@x", plan: "pro", org: "org-m"), login: credsM, profile: profile("m@x", org: "org-m"))
        try w.store.write { try $0.noteInstalled(.claude, m) }
        try w.writeClaude(config: claudeConfig(profile("o@x", org: "org-o")), creds: credsM)
        #expect(throws: KibaError.mixed) { try sw.save(.claude) }
        #expect(try w.store.list(.claude).map(\.name.raw) == ["m@x"])
    }
}

// MARK: - World

enum Fixed {
    /// 2026-09-21T14:13:20Z.
    static let now = 1_790_000_000
    static let hour = 3_600
    static let day = 86_400
    static let msPerSecond = 1_000
    /// Seconds a refreshed access token lives, as the token endpoints answer.
    static let tokenLife = 28_800
    /// Longer than half of `security -i`'s 4096-byte line once hex-encoded.
    static let bigSecret = 3_000
    /// Keychain account of the live Claude item; never the user's, so a stray
    /// lookup cannot reach real credentials.
    static let user = "kiba-mac-test-user"
    static let keychainPrefix = "kiba-mac-test-"
    /// How long the app model may take to finish a read or an action.
    static let settleLimit = Duration.seconds(5)
    static let pollStep = Duration.milliseconds(10)
    /// Under /private/tmp: the store refuses symlinked paths such as /tmp.
    static let scratchTemplate = "/private/tmp/kiba-it-XXXXXX"
    static let shell = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
    static let security = URL(fileURLWithPath: "/usr/bin/security", isDirectory: false)
    /// The default keychain `security` looks for under HOME.
    static let loginKeychain = "login.keychain-db"
    /// Where the login script finds `mv`.
    static let systemPath = "/usr/bin:/bin"
    static let execMode = 0o755
    /// A directory that lists and reads but takes no new file.
    static let lockedMode = 0o500
    static let openMode = 0o700
    /// `Fixed.now + hour` and `Fixed.now + 4 days` in ISO 8601.
    static let sessionReset = "2026-09-21T15:13:20Z"
    static let weekReset = "2026-09-25T14:13:20Z"
    static let weekResetDays = 4
}

enum Status {
    static let ok = 200
    static let unauthorized = 401
}

enum Endpoint {
    static let claudeUsage = "https://api.anthropic.com/api/oauth/usage"
    static let claudeToken = "https://platform.claude.com/v1/oauth/token"
    static let codexUsage = "https://chatgpt.com/backend-api/wham/usage"
}

enum Header {
    static let auth = "Authorization"
    static let agent = "User-Agent"
}

/// One test's scratch HOME, live-login directories and PATH, with the store
/// inside that HOME.
struct World: Sendable {
    let dir: URL
    let bin: URL
    let env: [String: String]
    let paths: Paths
    let store: Store
    let clock: Clock = { Date(timeIntervalSince1970: TimeInterval(Fixed.now)) }

    init() throws {
        var template = Array(Fixed.scratchTemplate.utf8CString)
        let path = try template.withUnsafeMutableBufferPointer { buf -> String in
            guard let made = mkdtemp(buf.baseAddress) else { throw KibaError.io("mkdtemp \(Fixed.scratchTemplate): errno \(errno)") }
            return String(cString: made)
        }
        dir = URL(fileURLWithPath: path, isDirectory: true)
        bin = dir.appending(component: "bin")
        var env: [String: String] = ["PATH": bin.path]
        for (key, sub) in [("HOME", "home"), (Provider.claude.homeVar, "claude"), (Provider.codex.homeVar, "codex")] {
            env[key] = dir.appending(component: sub).path
        }
        for sub in ["home", "claude", "codex", "bin"] {
            try FileManager.default.createDirectory(at: dir.appending(component: sub), withIntermediateDirectories: false)
        }
        self.env = env
        paths = try Paths(env: env, username: Fixed.user)
        store = try Store(paths: paths)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: dir)
    }

    func switcher(_ http: StubHTTP) -> Switcher {
        Switcher(paths: paths, store: store, http: http, clock: clock)
    }

    /// `during` stands for what the provider login does outside its home.
    func runner(_ http: StubHTTP, keychain: FakeKeychain, during: @escaping @Sendable () throws -> Void = {}) -> LoginRunner {
        var shellEnv = env
        shellEnv["PATH"] = "\(bin.path):\(Fixed.systemPath)"
        return LoginRunner(
            paths: paths, switcher: switcher(http), terminal: ShellTerminal(env: shellEnv, during: during),
            lister: keychain, searchPath: bin.path)
    }

    func writeClaude(config: Data, creds: Data) throws {
        try config.write(to: paths.claudeConfigFile(root: nil))
        try creds.write(to: paths.claudeCredsFile(root: nil))
    }

    func writeCodex(_ auth: Data) throws {
        try auth.write(to: paths.codexAuthFile(root: nil))
    }

    func seed(
        _ p: Provider, _ name: SlotName, _ id: Identity, login: Data, profile: Data?, usage: UsageRecord? = nil
    ) throws {
        try store.write { try $0.put(p, SavedLogin(name: name, identity: id, login: login, profile: profile, usage: usage)) }
    }

    /// A `name` executable on the scratch PATH running `body` under `/bin/sh`.
    func fakeCLI(_ name: String, _ body: String) throws {
        let url = bin.appending(component: name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: Fixed.execMode], ofItemAtPath: url.path)
    }

    /// The file's bytes; nil when it does not exist.
    func read(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: url.path)
    }
}

/// Runs `body` in a fresh world, then removes the world.
func scratch(_ body: (World) async throws -> Void) async throws {
    let w = try World()
    do {
        try await body(w)
    } catch {
        try w.remove()
        throw error
    }
    try w.remove()
}

/// Runs the login script at once with `/bin/sh`, as Terminal would, then
/// `during`. A script that ends without reporting its exit status fails here,
/// so `add` cannot wait forever.
struct ShellTerminal: TerminalLauncher {
    let env: [String: String]
    let during: @Sendable () throws -> Void

    func open(_ script: URL) throws {
        let r = try Subprocess.run(Fixed.shell, [script.path], stdin: nil, env: env, setsid: true)
        let exit = script.deletingLastPathComponent().appending(component: "exit")
        guard FileManager.default.fileExists(atPath: exit.path) else {
            throw KibaError.tool(script.path, r.status, text(r.stderr))
        }
        try during()
    }
}

/// The Keychain as `add` sees it, one in-memory item per service.
struct FakeKeychain: KeychainLister {
    let items: [String: MemorySecret]

    func services(prefix: String) throws -> Set<String> {
        Set(try items.filter { try $0.key.hasPrefix(prefix) && $0.value.read() != nil }.keys)
    }

    /// An unknown service is an absent item.
    func item(_ service: String) -> SecretStore {
        items[service] ?? MemorySecret(nil)
    }
}

/// `security` works on the default keychain of this process's HOME. Under
/// `test.sh` that HOME is a scratch directory with none, where an add blocks
/// on a "keychain not found" prompt; give it a throwaway keychain there. A
/// real home is never given one.
func ensureKeychain() throws {
    let found = try Subprocess.run(Fixed.security, ["default-keychain"], stdin: nil, env: nil, setsid: true)
    guard found.status != 0 else { return }
    let home = try #require(ProcessInfo.processInfo.environment["HOME"])
    let account = String(cString: try #require(getpwuid(getuid())).pointee.pw_dir)
    try #require(home != account, "no default keychain in the real home \(home)")
    let dir = URL(fileURLWithPath: home).appending(components: "Library", "Keychains")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(component: Fixed.loginKeychain).path
    let made = try Subprocess.run(Fixed.security, ["create-keychain", "-p", "", file], stdin: nil, env: nil, setsid: true)
    guard made.status == 0 else { throw KibaError.tool(Fixed.security.path, made.status, text(made.stderr)) }
}

// MARK: - Fixtures

func slot(_ raw: String) throws -> SlotName {
    try #require(SlotName(raw))
}

func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

func answer(_ status: Int, _ body: String) -> HTTPOutcome {
    .response(HTTPResponse(status: status, body: Data(body.utf8)))
}

/// Claude credentials whose tokens are `at-<tag>` / `rt-<tag>`; `expires` in epoch seconds.
func claudeCreds(_ tag: String, plan: String, expires: Int) -> Data {
    Data(#"""
        {"claudeAiOauth":{"accessToken":"at-\#(tag)","refreshToken":"rt-\#(tag)","expiresAt":\#(expires * Fixed.msPerSecond),"scopes":["user:inference","user:profile"],"subscriptionType":"\#(plan)"}}
        """#.utf8)
}

/// An `oauthAccount` object, spaced as Claude Code writes it.
func profile(_ email: String, org: String) -> Data {
    Data(#"{ "accountUuid": "acc-\#(email)", "emailAddress": "\#(email)", "organizationUuid": "\#(org)", "displayName": "T" }"#.utf8)
}

/// A `.claude.json` with `profile` among members a re-serialiser would change.
func claudeConfig(_ profile: Data) -> Data {
    let head = #"{"numStartups":42,  "tipsHistory": {"new-user-warmup": 7}, "big": 1e3, "oauthAccount": "#
    let tail = #", "projects": {"/w/é": {"allowedTools": [], "history": ["é", 1.50]}}, "userID": "f00d"}"# + "\n"
    return Data(head.utf8) + profile + Data(tail.utf8)
}

/// A Codex `auth.json` whose id_token names `email`, and whose tokens are `at-<tag>` / `rt-<tag>`.
func codexAuth(_ email: String, plan: String, account: String, tag: String) -> Data {
    let claims = #"{"email":"\#(email)","https://api.openai.com/auth":{"chatgpt_plan_type":"\#(plan)","chatgpt_account_id":"\#(account)"}}"#
    let jwt = [#"{"alg":"none","typ":"JWT"}"#, claims].map { base64url(Data($0.utf8)) }.joined(separator: ".") + ".sig"
    return Data("""
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "\(jwt)",
            "access_token": "at-\(tag)",
            "refresh_token": "rt-\(tag)",
            "account_id": "\(account)"
          },
          "last_refresh": "2026-09-20T08:00:00Z"
        }

        """.utf8)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
}

/// Anthropic's usage answer: session and week used, plus an Opus weekly window.
func claudeUsage(session: Int, week: Int, opus: Int? = nil) -> String {
    let model = opus.map {
        #","limits":[{"kind":"weekly","percent":\#($0),"resets_at":"\#(Fixed.weekReset)","scope":{"model":{"display_name":"Opus"}}}]"#
    } ?? ""
    return #"{"five_hour":{"utilization":\#(session),"resets_at":"\#(Fixed.sessionReset)"},"#
        + #""seven_day":{"utilization":\#(week),"resets_at":"\#(Fixed.weekReset)"}\#(model)}"#
}

/// ChatGPT's usage answer: a 5-hour and a 7-day window.
func codexUsage(session: Int, week: Int) -> String {
    let sessionAt = Fixed.now + Fixed.hour, weekAt = Fixed.now + Fixed.weekResetDays * Fixed.day
    return #"{"rate_limit":{"primary_window":{"used_percent":\#(session),"limit_window_seconds":18000,"reset_at":\#(sessionAt)},"#
        + #""secondary_window":{"used_percent":\#(week),"limit_window_seconds":604800,"reset_at":\#(weekAt)}}}"#
}

func windows(session: Int, week: Int) -> [Limit] {
    [Limit(label: "Session (5-hour)", percent: session, resetsAt: Fixed.sessionReset),
     Limit(label: "Weekly (7-day)", percent: week, resetsAt: Fixed.weekReset)]
}

func probed(_ limits: [Limit]) -> UsageRecord {
    UsageRecord(fetchedAt: Fixed.now, state: .ok, note: "", limits: limits)
}

// MARK: - App model

@MainActor @Test func appModelListsRowsAndSwitches() async throws {
    let w = try World()
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (ay, by) = (try slot("a@y"), try slot("b@y"))
    let liveAuth = codexAuth("a@y", plan: "plus", account: "acct-a", tag: "ya")
    try w.writeCodex(liveAuth)
    try w.seed(.codex, ay, Identity(email: "a@y", plan: "plus", org: "acct-a"), login: liveAuth, profile: nil)
    try w.seed(.codex, by, Identity(email: "b@y", plan: "pro", org: "acct-b"),
               login: codexAuth("b@y", plan: "pro", account: "acct-b", tag: "yb"), profile: nil)
    let http = StubHTTP([answer(Status.ok, codexUsage(session: 20, week: 45)),
                         answer(Status.ok, codexUsage(session: 15, week: 25))])
    let backend = CoreBackend(
        switcher: w.switcher(http), reader: StatusReader(paths: w.paths, store: w.store),
        runner: w.runner(http, keychain: FakeKeychain(items: [:])))
    let model = AppModel(connect: { backend })

    model.start()
    try await settle(model)
    #expect(model.availability == .ready)
    let before = model.sections.first { $0.id == .codex }
    #expect(before?.accounts.map(\.name) == [ay, by])
    #expect(before?.accounts.map(\.active) == [true, false])
    #expect(model.actions.contains(.use(.codex, by)))

    model.use(.codex, by)
    #expect(model.busy)
    try await settle(model)
    #expect(model.message == "Codex: now b@y")
    #expect(model.error == "")
    let after = model.snapshot.providers.first { $0.provider == .codex }
    #expect(after?.live == LiveLogin(email: "b@y", plan: "pro"))
    #expect(after?.accounts == [
        Account(name: ay, plan: "plus", active: false, usage: probed(windows(session: 15, week: 25))),
        Account(name: by, plan: "pro", active: true, usage: probed(windows(session: 20, week: 45))),
    ])
}

/// Waits until the model has no read or action in flight.
@MainActor func settle(_ model: AppModel) async throws {
    let clock = ContinuousClock()
    let end = clock.now + Fixed.settleLimit
    while model.busy || model.refreshing {
        try #require(clock.now < end, "the model did not settle")
        try await Task.sleep(for: Fixed.pollStep)
    }
}
