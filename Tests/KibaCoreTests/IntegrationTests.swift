import Foundation
import KibaCore
import SQLite3
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

        // Days later a@x's saved tokens have expired. The live credentials
        // are still a@x's, so a probe must not spend a@x's refresh grant.
        let http = StubHTTP([
            answer(Status.ok, #"{"access_token":"at-xa5","refresh_token":"rt-xa5","expires_in":\#(Fixed.tokenLife)}"#),
            answer(Status.ok, claudeUsage(session: 10, week: 20)),
        ])
        let later = Switcher(paths: w.paths, store: w.store, http: http) {
            Date(timeIntervalSince1970: TimeInterval(Fixed.now + Fixed.later))
        }
        #expect(await later.probeAll(.claude).saveBackError == KibaError.mixed.reason)
        #expect(!http.requests.contains { $0.url.absoluteString == Endpoint.claudeToken })
        #expect(try w.store.list(.claude).map(\.login) == [refreshed, credsB])
    }
}

@Test func switchMovesKeychainLiveLogin() async throws {
    try ensureKeychain()
    let service = "\(Fixed.keychainPrefix)\(UUID().uuidString)"
    let item = KeychainItem(service: service, account: Fixed.user)
    defer { #expect(throws: Never.self) { try item.remove() } }
    try await scratch(keychainService: service) { w in
        let (ax, bx) = (try slot("a@x"), try slot("b@x"))
        let liveCreds = claudeCreds("xa2", plan: "max", expires: Fixed.now + Fixed.day)
        let credsB = claudeCreds("xb", plan: "pro", expires: Fixed.now + Fixed.day)
        let profA = profile("a@x", org: "org-a"), profB = profile("b@x", org: "org-b")
        // No credentials file: the live login is the Keychain item.
        try claudeConfig(profA).write(to: w.paths.claudeConfigFile(root: nil))
        try item.write(liveCreds)
        try w.seed(.claude, ax, Identity(email: "a@x", plan: "max", org: "org-a"),
                   login: claudeCreds("xa1", plan: "max", expires: Fixed.now), profile: profA)
        try w.seed(.claude, bx, Identity(email: "b@x", plan: "pro", org: "org-b"), login: credsB, profile: profB)
        let http = StubHTTP([answer(Status.ok, claudeUsage(session: 30, week: 60)),
                             answer(Status.ok, claudeUsage(session: 10, week: 20))])

        try await w.switcher(http).use(.claude, bx)

        #expect(try item.read() == credsB)
        #expect(w.read(w.paths.claudeCredsFile(root: nil)) == nil)
        #expect(w.read(w.paths.claudeConfigFile(root: nil)) == claudeConfig(profB))
        #expect(try w.store.fetch(.claude, ax)?.login == liveCreds)
        #expect(try w.store.installed(.claude) == bx)
        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-xb", "Bearer at-xa2"])
        let claude = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .claude }
        #expect(claude?.live == LiveLogin(email: "b@x", plan: "pro"))
        #expect(claude?.accounts.map(\.active) == [false, true])
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

@Test func orphanClaudeCredsStopProbesAndSwitches() async throws {
    try await scratch { w in
        let (ax, bx) = (try slot("a@x"), try slot("b@x"))
        let credsA = claudeCreds("xa", plan: "max", expires: Fixed.now - Fixed.hour)
        let credsB = claudeCreds("xb", plan: "pro", expires: Fixed.now + Fixed.day)
        try w.seed(.claude, ax, Identity(email: "a@x", plan: "max", org: "org-a"), login: credsA, profile: profile("a@x", org: "org-a"))
        try w.seed(.claude, bx, Identity(email: "b@x", plan: "pro", org: "org-b"), login: credsB, profile: profile("b@x", org: "org-b"))
        // The config is gone but the credentials are still a@x's: refreshing
        // the saved a@x would spend the refresh grant the live login holds.
        try credsA.write(to: w.paths.claudeCredsFile(root: nil))
        let http = StubHTTP([])
        let sw = w.switcher(http)
        let orphan = KibaError.orphanLive(w.paths.claudeConfigFile(root: nil))

        let report = await sw.probeAll(.claude)

        #expect(report.saveBackError == orphan.reason)
        #expect(report.providerError == orphan.reason)
        #expect(report.accounts.isEmpty)
        #expect(http.requests.isEmpty)
        #expect(try w.store.fetch(.claude, ax)?.login == credsA)
        await #expect(throws: orphan) { try await sw.use(.claude, bx) }
        #expect(w.read(w.paths.claudeCredsFile(root: nil)) == credsA)
        #expect(w.read(w.paths.claudeConfigFile(root: nil)) == nil)
        let claude = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .claude }
        #expect(claude?.error == orphan.reason)
        #expect(claude?.live == nil)
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

@Test(arguments: ProbeCase.all) func probeKeepsSavedLoginWhenCheckFails(_ c: ProbeCase) async throws {
    try await scratch { w in
        let name = try slot(ProbeCase.email)
        try w.seed(c.provider, name, Identity(email: ProbeCase.email, plan: "pro", org: "org-s"), login: c.login,
                   profile: c.provider == .claude ? profile(ProbeCase.email, org: "org-s") : nil)
        let http = StubHTTP(c.answers)

        let report = await w.switcher(http).probeAll(c.provider)

        #expect(report.providerError == nil)
        #expect(http.requests.count == c.answers.count)
        let status = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == c.provider }
        #expect(status?.accounts == [Account(
            name: name, plan: "pro", active: false,
            usage: UsageRecord(fetchedAt: Fixed.now, state: c.state, note: c.note, limits: []))])
        #expect(try w.store.fetch(c.provider, name)?.login == c.login)
    }
}

/// A saved login whose check fails: what the provider answers, in order, and
/// the state and note its row then shows.
struct ProbeCase: Sendable, CustomTestStringConvertible {
    let provider: Provider
    let login: Data
    let answers: [HTTPOutcome]
    let state: UsageState
    let note: String

    var testDescription: String { "\(provider.rawValue): \(note)" }

    static let email = "s@x"
    /// Expired, so the check starts with a refresh.
    static let stale = claudeCreds("s", plan: "pro", expires: Fixed.now - Fixed.hour)
    static let fresh = claudeCreds("s", plan: "pro", expires: Fixed.now + Fixed.day)
    static let auth = codexAuth(email, plan: "pro", account: "org-s", tag: "s")
    /// A rejected access token the provider has not revoked: it earns a refresh.
    static let rejected = answer(Status.unauthorized, #"{"error":{"code":"token_expired"}}"#)
    static let down = HTTPOutcome.unreachable("host down")

    static let all = [
        ProbeCase(provider: .claude, login: stale, answers: [answer(Status.badRequest, #"{"error":"invalid_grant"}"#)],
                  state: .expired, note: "access token expired and the refresh was refused; log in again"),
        ProbeCase(provider: .claude, login: stale, answers: [answer(Status.serverError, "")],
                  state: .error, note: "Anthropic's token endpoint answered 500"),
        ProbeCase(provider: .claude, login: fresh, answers: [down],
                  state: .error, note: "Anthropic's usage endpoint could not be reached"),
        ProbeCase(provider: .claude, login: fresh, answers: [answer(Status.tooMany, "{}")],
                  state: .error, note: "Anthropic is rate limiting usage checks; try again later"),
        ProbeCase(provider: .codex, login: auth, answers: [rejected, answer(Status.badRequest, #"{"error":"invalid_grant"}"#)],
                  state: .expired, note: "access token rejected and the refresh was refused; log in again"),
        ProbeCase(provider: .codex, login: auth, answers: [rejected, down],
                  state: .error, note: "OpenAI's token endpoint could not be reached"),
        ProbeCase(provider: .codex, login: auth, answers: [answer(Status.serverError, "")],
                  state: .error, note: "OpenAI's usage endpoint answered 500"),
        ProbeCase(provider: .codex, login: auth, answers: [answer(Status.tooMany, "{}")],
                  state: .error, note: "OpenAI is rate limiting usage checks; try again later"),
    ]
}

// MARK: - Limit resets

@Test func probeReadsClaudeResetOffers() async throws {
    try await scratch { w in
        for tag in ["a", "b", "c"] {
            try w.seed(.claude, try slot("\(tag)@x"), Identity(email: "\(tag)@x", plan: "max", org: "org-\(tag)"),
                       login: claudeCreds(tag, plan: "max", expires: Fixed.now + Fixed.day), profile: profile("\(tag)@x", org: "org-\(tag)"))
        }
        let http = StubHTTP([
            answer(Status.ok, claudeUsage(session: 100, week: 60, resets: cedarBlock(left: 2))),
            answer(Status.ok, claudeUsage(session: 100, week: 60, resets: juniperBlock(available: true))),
            answer(Status.ok, claudeUsage(session: 30, week: 60)),
        ])

        _ = await w.switcher(http).probeAll(.claude)

        #expect(http.requests.map(\.url.absoluteString) == Array(repeating: Endpoint.claudeUsage, count: 3))
        let status = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .claude }
        #expect(status?.accounts.map(\.usage?.resets) == [
            ResetOffer(count: 2, program: "cedar_ember", grant: "grant-1"),
            ResetOffer(count: 1, program: "juniper_tide", grant: ""),
            nil,
        ])
    }
}

@Test func probeReadsCodexResetCredits() async throws {
    try await scratch { w in
        try w.seed(.codex, try slot("s@y"), Identity(email: "s@y", plan: "plus", org: "acct-s"),
                   login: codexAuth("s@y", plan: "plus", account: "acct-s", tag: "s"), profile: nil)
        let http = StubHTTP([answer(Status.ok, codexUsage(session: 100, week: 40, credits: 3))])

        _ = await w.switcher(http).probeAll(.codex)

        let status = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .codex }
        #expect(status?.accounts.first?.usage == UsageRecord(
            fetchedAt: Fixed.now, state: .ok, note: "", limits: windows(session: 100, week: 40),
            resets: ResetOffer(count: 3, program: "", grant: "")))
    }
}

@Test func redeemCodexResetsAndReprobes() async throws {
    try await scratch { w in
        let name = try slot("s@y")
        try w.seed(.codex, name, Identity(email: "s@y", plan: "plus", org: "acct-s"),
                   login: codexAuth("s@y", plan: "plus", account: "acct-s", tag: "s"), profile: nil)
        let http = StubHTTP([
            answer(Status.ok, codexUsage(session: 100, week: 40, credits: 3)),
            answer(Status.ok, #"{"code":"reset"}"#),
            answer(Status.ok, codexUsage(session: 0, week: 40, credits: 2)),
        ])
        let sw = w.switcher(http)
        _ = await sw.probeAll(.codex)

        #expect(try await sw.redeem(.codex, name) == .reset)

        #expect(http.requests.map(\.url.absoluteString) == [Endpoint.codexUsage, Endpoint.codexConsume, Endpoint.codexUsage])
        let post = http.requests[1]
        #expect(post.method == "POST")
        #expect(post.headers[Header.auth] == "Bearer at-s")
        #expect(post.headers[Header.account] == "acct-s")
        #expect(post.headers[Header.agent] == "codex-cli")
        let body = try members(post.body)
        #expect(Array(body.keys) == ["redeem_request_id"])
        #expect(UUID(uuidString: body["redeem_request_id"] ?? "") != nil)
        let status = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .codex }
        #expect(status?.accounts.first?.usage == UsageRecord(
            fetchedAt: Fixed.now, state: .ok, note: "", limits: windows(session: 0, week: 40),
            resets: ResetOffer(count: 2, program: "", grant: "")))
    }
}

@Test func redeemClaudeGrantRefreshesSavedLoginFirst() async throws {
    try await scratch { w in
        let name = try slot("b@x")
        let offer = ResetOffer(count: 2, program: "cedar_ember", grant: "grant-1")
        try w.seed(.claude, name, Identity(email: "b@x", plan: "max", org: Fixed.org),
                   login: claudeCreds("b", plan: "max", expires: Fixed.now - Fixed.hour), profile: profile("b@x", org: Fixed.org),
                   usage: UsageRecord(fetchedAt: Fixed.now - Fixed.day, state: .ok, note: "", limits: [], resets: offer))
        let http = StubHTTP([
            answer(Status.ok, #"{"access_token":"at-b2","refresh_token":"rt-b2","expires_in":\#(Fixed.tokenLife)}"#),
            answer(Status.ok, #"{"result":"already_used"}"#),
            answer(Status.ok, claudeUsage(session: 30, week: 60, resets: cedarBlock(left: 2))),
        ])

        #expect(try await w.switcher(http).redeem(.claude, name) == .alreadyUsed)

        #expect(http.requests.map(\.url.absoluteString) == [Endpoint.claudeToken, Endpoint.claudeReset, Endpoint.claudeUsage])
        let post = http.requests[1]
        #expect(post.method == "POST")
        #expect(post.headers[Header.auth] == "Bearer at-b2")
        #expect(post.headers[Header.beta] == "oauth-2025-04-20")
        #expect(post.headers[Header.contentType] == "application/json")
        #expect(post.headers[Header.agent] == "kiba")
        let body = try members(post.body)
        #expect(body.keys.sorted() == ["grant_id", "program", "request_id"])
        #expect(body["program"] == "cedar_ember")
        #expect(body["grant_id"] == "grant-1")
        #expect(UUID(uuidString: body["request_id"] ?? "") != nil)
        let row = try w.store.fetch(.claude, name)
        #expect(row?.login == claudeCreds("b2", plan: "max", expires: Fixed.now + Fixed.tokenLife))
        #expect(row?.usage == probed(windows(session: 30, week: 60), resets: offer))
    }
}

@Test func redeemNeedsOfferAndNeverRefreshesLive() async throws {
    try await scratch { w in
        let liveAuth = codexAuth("live@y", plan: "plus", account: "acct-l", tag: "l")
        try w.writeCodex(liveAuth)
        let live = try slot("live@y"), old = try slot("old@y")
        try w.seed(.codex, old, Identity(email: "old@y", plan: "plus", org: "acct-o"),
                   login: codexAuth("old@y", plan: "plus", account: "acct-o", tag: "o"), profile: nil)
        try w.storeUsageText(.codex, old, Fixed.preResetUsage)
        let http = StubHTTP([
            answer(Status.ok, codexUsage(session: 100, week: 40, credits: 1)),
            answer(Status.ok, codexUsage(session: 20, week: 40)),
            answer(Status.unauthorized, #"{"error":{"code":"token_expired"}}"#),
        ])
        let sw = w.switcher(http)

        let before = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .codex }
        #expect(before?.accounts.map(\.usage) == [UsageRecord(
            fetchedAt: Fixed.now - Fixed.day, state: .ok, note: "",
            limits: [Limit(label: "Session (5-hour)", percent: 100, resetsAt: Fixed.sessionReset)])])
        await #expect(throws: KibaError.noResets(.codex, "old@y")) { try await sw.redeem(.codex, old) }
        #expect(http.requests.isEmpty)

        _ = await sw.probeAll(.codex)
        await #expect(throws: KibaError.remote("access token rejected; run codex once to refresh it")) {
            try await sw.redeem(.codex, live)
        }

        #expect(http.requests.map(\.url.absoluteString) == [Endpoint.codexUsage, Endpoint.codexUsage, Endpoint.codexConsume])
        #expect(try w.store.fetch(.codex, live)?.login == liveAuth)
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

/// A probed row's hover lines count the limit resets it offers, after its
/// windows; a row with none left says nothing about them.
@Test func rowsTooltipCountsLimitResets() async throws {
    try await scratch { w in
        for tag in ["a", "b"] {
            try w.seed(.codex, try slot("\(tag)@y"), Identity(email: "\(tag)@y", plan: "plus", org: "acct-\(tag)"),
                       login: codexAuth("\(tag)@y", plan: "plus", account: "acct-\(tag)", tag: tag), profile: nil)
        }
        let http = StubHTTP([
            answer(Status.ok, codexUsage(session: 100, week: 40, credits: 2)),
            answer(Status.ok, codexUsage(session: 30, week: 40, credits: 0)),
        ])
        _ = await w.switcher(http).probeAll(.codex)

        let codex = StatusReader(paths: w.paths, store: w.store).read().providers.first { $0.provider == .codex }
        let now = Date(timeIntervalSince1970: TimeInterval(Fixed.now))
        let tips = try #require(codex).accounts.map { Rows.tooltip(.codex, $0, now: now) }
        #expect(tips == [
            ["a@y · plus", "Session (5-hour): limit reached · resets in 1 h 0 min",
             "Weekly (7-day): 60% left · resets in 4 days", "2 limit resets available",
             "Probed just now", "Click to switch Codex to this account"],
            ["b@y · plus", "Session (5-hour): 70% left · resets in 1 h 0 min",
             "Weekly (7-day): 60% left · resets in 4 days",
             "Probed just now", "Click to switch Codex to this account"],
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
        #expect(w.calls() == ["codex login"])
    }
}

@Test func addClaudeFromFileAndFromKeychain() async throws {
    try await scratch { w in
        let liveCreds = claudeCreds("live", plan: "max", expires: Fixed.now + Fixed.day)
        let keychain = FakeKeychain(items: [w.paths.keychainService: MemorySecret(liveCreds)])
        let http = StubHTTP([answer(Status.ok, claudeUsage(session: 30, week: 60)),
                             answer(Status.ok, claudeUsage(session: 30, week: 60)),
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
        let runner = try w.runner(http, keychain: keychain) { try live.write(newCreds) }
        let added = try await runner.add(.claude, expected: "k@y")
        #expect(added == AddResult(saved: try slot("k@y"), expected: "k@y", differs: false))
        #expect(try w.store.fetch(.claude, try slot("k@y"))?.login == newCreds)
        #expect(try live.read() == liveCreds)

        // The same login with no live item, as when the live credentials are a
        // file: the item it creates is removed.
        try live.remove()
        let itemCreds = claudeCreds("f", plan: "pro", expires: Fixed.now + Fixed.day)
        try w.fakeCLI("claude", """
            printf '%s' '\(text(claudeConfig(profile("f@y", org: "org-f"))))' > "$CLAUDE_CONFIG_DIR/.claude.json"
            """)
        let created = try await w.runner(http, keychain: keychain) { try live.write(itemCreds) }.add(.claude, expected: "f@y")
        #expect(created == AddResult(saved: try slot("f@y"), expected: "f@y", differs: false))
        #expect(try w.store.fetch(.claude, try slot("f@y"))?.login == itemCreds)
        #expect(try live.read() == nil)

        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-o", "Bearer at-k", "Bearer at-f"])
        #expect(!FileManager.default.fileExists(atPath: w.paths.loginRoot(.claude).path))
        #expect(w.calls() == [
            "claude auth login --email x@y", "claude auth login --email k@y", "claude auth login --email f@y",
        ])
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
        let runner = try w.runner(http, keychain: keychain) { try leftover.write(newCreds) }

        let added = try await runner.add(.claude, expected: "n@y")

        #expect(added == AddResult(saved: try slot("n@y"), expected: "n@y", differs: false))
        #expect(try w.store.fetch(.claude, try slot("n@y"))?.login == newCreds)
        #expect(try leftover.read() == nil)
        #expect(try keychain.item(w.paths.keychainService).read() == liveCreds)
        #expect(http.requests.map { $0.headers[Header.auth] } == ["Bearer at-n"])
        #expect(w.calls() == ["claude auth login --email n@y"])
    }
}

@Test func addReportsMissingCLIAndFailedLogin() async throws {
    try await scratch { w in
        let runner = try w.runner(StubHTTP([]), keychain: FakeKeychain(items: [:]))
        await #expect(throws: KibaError.noCLI("codex")) { try await runner.add(.codex, expected: nil) }
        try w.fakeCLI("codex", "exit 3")
        await #expect(throws: KibaError.loginFailed(3)) { try await runner.add(.codex, expected: nil) }
        #expect(w.calls() == ["codex login"])
        #expect(try w.store.list(.codex).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: w.paths.loginRoot(.codex).path))
    }
}

@Test func addPutsLiveItemBackWhateverLoginDoes() async throws {
    try await scratch { w in
        let liveCreds = claudeCreds("live", plan: "max", expires: Fixed.now + Fixed.day)
        let keychain = FakeKeychain(items: [w.paths.keychainService: MemorySecret(liveCreds)])
        let live = keychain.item(w.paths.keychainService)
        let http = StubHTTP([answer(Status.ok, claudeUsage(session: 30, week: 60))])

        // A login that overwrites the live item and then fails.
        try w.fakeCLI("claude", "exit 3")
        let failing = try w.runner(http, keychain: keychain) {
            try live.write(claudeCreds("x", plan: "pro", expires: Fixed.now + Fixed.day))
        }
        await #expect(throws: KibaError.loginFailed(3)) { try await failing.add(.claude, expected: "x@y") }
        #expect(try live.read() == liveCreds)

        // A login that writes a credentials file and overwrites the live item too.
        let fileCreds = claudeCreds("f", plan: "pro", expires: Fixed.now + Fixed.day)
        try w.fakeCLI("claude", """
            printf '%s' '\(text(fileCreds))' > "$CLAUDE_CONFIG_DIR/.credentials.json"
            printf '%s' '\(text(claudeConfig(profile("f@y", org: "org-f"))))' > "$CLAUDE_CONFIG_DIR/.claude.json"
            """)
        let both = try w.runner(http, keychain: keychain) {
            try live.write(claudeCreds("k", plan: "pro", expires: Fixed.now + Fixed.day))
        }
        let added = try await both.add(.claude, expected: "f@y")
        #expect(added == AddResult(saved: try slot("f@y"), expected: "f@y", differs: false))
        #expect(try w.store.fetch(.claude, try slot("f@y"))?.login == fileCreds)
        #expect(try live.read() == liveCreds)
        #expect(!FileManager.default.fileExists(atPath: w.paths.loginRoot(.claude).path))
    }
}

@Test func cancelledAddStopsLoginAndPutsLiveItemBack() async throws {
    try await scratch { w in
        let liveCreds = claudeCreds("live", plan: "max", expires: Fixed.now + Fixed.day)
        let keychain = FakeKeychain(items: [w.paths.keychainService: MemorySecret(liveCreds)])
        let live = keychain.item(w.paths.keychainService)
        // A login that overwrites the live item, then waits on the browser.
        let cliPid = w.dir.appending(component: "cli.pid")
        try w.fakeCLI("claude", "printf '%s' \"$$\" > '\(cliPid.path)'\nsleep \(Fixed.stall)")
        let runner = try w.runner(StubHTTP([]), keychain: keychain, background: true) {
            try live.write(claudeCreds("x", plan: "pro", expires: Fixed.now + Fixed.day))
        }
        let add = Task { try await runner.add(.claude, expected: "x@y") }
        try await until("the login to start") { w.read(cliPid) != nil }

        add.cancel()

        let exit = w.paths.loginRoot(.claude).appending(component: "exit")
        await #expect(throws: KibaError.io("login wait cancelled before \(exit.path) appeared")) { try await add.value }
        #expect(try live.read() == liveCreds)
        let pid = try #require(w.read(cliPid).flatMap { pid_t(text($0)) })
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "the login still runs")
        #expect(!FileManager.default.fileExists(atPath: w.paths.loginRoot(.claude).path))
    }
}

@Test func addWhileLoginRunsIsRefused() async throws {
    try await scratch { w in
        let signedIn = w.dir.appending(component: "signed-in")
        let auth = codexAuth("new@y", plan: "pro", account: "acct-n", tag: "n")
        // A login that waits until the test signs in, for `Fixed.stall` seconds at most.
        try w.fakeCLI("codex", """
            n=0
            while [ ! -e '\(signedIn.path)' ] && [ "$n" -lt \(Fixed.stall * Fixed.ticksPerSecond) ]; do
              sleep \(Fixed.tickSeconds); n=$((n + 1))
            done
            printf '%s' '\(text(auth))' > "$CODEX_HOME/auth.json"
            """)
        let http = StubHTTP([answer(Status.ok, codexUsage(session: 20, week: 45))])
        let runner = try w.runner(http, keychain: FakeKeychain(items: [:]), background: true)
        let first = Task { try await runner.add(.codex, expected: nil) }
        try await until("the first login to start") { !w.calls().isEmpty }

        let second = await #expect(throws: KibaError.self) { try await runner.add(.codex, expected: nil) }
        #expect(second?.reason == "a Codex login is already running")

        FileManager.default.createFile(atPath: signedIn.path, contents: nil)
        let added = try await finish(first)
        #expect(added == AddResult(saved: try slot("new@y"), expected: nil, differs: false))
        #expect(try w.store.fetch(.codex, try slot("new@y"))?.login == auth)
        #expect(w.calls() == ["codex login"])
    }
}

@Test func failedImportKeepsNewLogin() async throws {
    try await scratch { w in
        let liveCreds = claudeCreds("live", plan: "max", expires: Fixed.now + Fixed.day)
        let found = MemorySecret(nil)
        let keychain = FakeKeychain(items: [
            w.paths.keychainService: MemorySecret(liveCreds), "\(w.paths.keychainService)-login": found,
        ])
        // An account the store cannot name: a name holds no slash.
        let config = claudeConfig(profile("n/x@y", org: "org-n"))
        try w.fakeCLI("claude", "printf '%s' '\(text(config))' > \"$CLAUDE_CONFIG_DIR/.claude.json\"")
        let newCreds = claudeCreds("n", plan: "pro", expires: Fixed.now + Fixed.day)
        let runner = try w.runner(StubHTTP([]), keychain: keychain) { try found.write(newCreds) }

        await #expect(throws: KibaError.badName("n/x@y")) { try await runner.add(.claude, expected: nil) }

        #expect(try found.read() == newCreds)
        #expect(w.read(w.paths.claudeConfigFile(root: w.paths.loginRoot(.claude))) == config)
        #expect(try keychain.item(w.paths.keychainService).read() == liveCreds)
        #expect(try w.store.list(.claude).isEmpty)
    }
}

@Test func startUndoesAddTheAppDidNotFinish() async throws {
    try await scratch { w in
        // The app died while an add's login had overwritten the live item.
        let liveCreds = claudeCreds("live", plan: "max", expires: Fixed.now + Fixed.day)
        let live = MemorySecret(claudeCreds("x", plan: "pro", expires: Fixed.now + Fixed.day))
        let keychain = FakeKeychain(items: [w.paths.keychainService: live])
        try w.store.write { try $0.noteAdding(.claude, LiveItem(bytes: liveCreds)) }
        let root = w.paths.loginRoot(.claude)
        try FileManager.default.createDirectory(at: w.paths.claudeConfigDir(root: root), withIntermediateDirectories: true)

        _ = try w.runner(StubHTTP([]), keychain: keychain)

        #expect(try live.read() == liveCreds)
        #expect(try w.store.adding(.claude) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
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
    /// Long enough for every token the fixtures issue to expire.
    static let later = 2 * day
    static let msPerSecond = 1_000
    /// Seconds a refreshed access token lives, as the token endpoints answer.
    static let tokenLife = 28_800
    /// Longer than half of `security -i`'s 4096-byte line once hex-encoded.
    static let bigSecret = 3_000
    /// Keychain account of the live Claude item; never the user's, so a stray
    /// lookup cannot reach real credentials.
    static let user = "kiba-mac-test-user"
    static let keychainPrefix = "kiba-mac-test-"
    /// The service of tests that never touch the Keychain: no item is ever filed under it.
    static let noKeychain = "kiba-mac-test-none"
    /// How long the app model may take to finish a read or an action.
    static let settleLimit = Duration.seconds(5)
    static let pollStep = Duration.milliseconds(10)
    /// Why the store cannot be opened while a test holds the app offline.
    static let offline = "store offline"
    /// Seconds a fake login waits for a sign-in that never comes.
    static let stall = 10
    /// How often a fake login looks for its sign-in.
    static let ticksPerSecond = 10
    static let tickSeconds = 1.0 / Double(ticksPerSecond)
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
    /// The Anthropic organization of the Claude login that redeems a reset.
    static let org = "5f1c2a9e-8d3b-4c7a-9e21-0b6d4f3a7c58"
    /// A usage column as kiba stored it before limit resets were read.
    static let preResetUsage = #"{"fetchedAt":\#(now - day),"limits":[{"label":"Session (5-hour)","percent":100,"#
        + #""resetsAt":"\#(sessionReset)"}],"note":"","state":"ok"}"#
}

enum Status {
    static let ok = 200
    static let badRequest = 400
    static let unauthorized = 401
    static let tooMany = 429
    static let serverError = 500
}

enum Endpoint {
    static let claudeUsage = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&at_wall=1"
    static let claudeReset = "https://api.anthropic.com/api/organizations/\(Fixed.org)/reset_rate_limits"
    static let claudeToken = "https://platform.claude.com/v1/oauth/token"
    static let codexUsage = "https://chatgpt.com/backend-api/wham/usage"
    static let codexConsume = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume"
}

enum Header {
    static let auth = "Authorization"
    static let agent = "User-Agent"
    static let account = "ChatGPT-Account-Id"
    static let beta = "anthropic-beta"
    static let contentType = "Content-Type"
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

    init(keychainService: String) throws {
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
        paths = try Paths(env: env, username: Fixed.user, keychainService: keychainService)
        store = try Store(paths: paths)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: dir)
    }

    func switcher(_ http: StubHTTP) -> Switcher {
        Switcher(paths: paths, store: store, http: http, clock: clock)
    }

    /// `during` stands for what the provider login does outside its home;
    /// with `background` the Terminal launch returns while the login runs.
    func runner(
        _ http: StubHTTP, keychain: FakeKeychain, background: Bool = false,
        during: @escaping @Sendable () throws -> Void = {}
    ) throws -> LoginRunner {
        var shellEnv = env
        shellEnv["PATH"] = "\(bin.path):\(Fixed.systemPath)"
        let terminal: any TerminalLauncher =
            background ? BackgroundTerminal(env: shellEnv, during: during) : ShellTerminal(env: shellEnv, during: during)
        return try LoginRunner(
            paths: paths, switcher: switcher(http), terminal: terminal, lister: keychain, searchPath: bin.path)
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

    /// A `name` executable on the scratch PATH running `body` under `/bin/sh`,
    /// once it has added its command line to `calls()`.
    func fakeCLI(_ name: String, _ body: String) throws {
        let url = bin.appending(component: name)
        let record = "printf '%s\\n' \"\(name) $*\" >> '\(callLog.path)'"
        try Data("#!/bin/sh\n\(record)\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: Fixed.execMode], ofItemAtPath: url.path)
    }

    var callLog: URL { dir.appending(component: "calls") }

    /// Every fake CLI run so far, oldest first, as `<name> <arguments>`.
    func calls() -> [String] {
        (read(callLog).map(text) ?? "").split(separator: "\n").map(String.init)
    }

    /// Stores `json` as the usage column of the saved login `n`, bypassing the
    /// record codec, as an older kiba wrote it.
    func storeUsageText(_ p: Provider, _ n: SlotName, _ json: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(paths.db.path, &db) == SQLITE_OK else { throw KibaError.db("open \(paths.db.path)") }
        let sql = "UPDATE account SET usage = '\(json)' WHERE provider = '\(p.rawValue)' AND name = '\(n.raw)'"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) == 1 else {
            throw KibaError.db("store usage: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// The file's bytes; nil when it does not exist.
    func read(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: url.path)
    }
}

/// Runs `body` in a fresh world, then removes the world.
/// `keychainService` names the throwaway item a Keychain-backed live login uses.
func scratch(keychainService: String = Fixed.noKeychain, _ body: (World) async throws -> Void) async throws {
    let w = try World(keychainService: keychainService)
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

/// Starts the login script with `/bin/sh` in a session of its own and
/// returns at once, as Terminal does, then runs `during`. The script runs on
/// until it ends or `add` stops it. Terminal's shell starts it with no signal
/// blocked, while this process's threads block the ones `add` stops it with,
/// and a spawned child inherits its thread's mask: the spawning thread
/// unblocks them first.
struct BackgroundTerminal: TerminalLauncher {
    let env: [String: String]
    let during: @Sendable () throws -> Void

    func open(_ script: URL) throws {
        let env = env
        Thread.detachNewThread {
            var none = sigset_t()
            sigemptyset(&none)
            precondition(pthread_sigmask(SIG_SETMASK, &none, nil) == 0, "the signal mask did not clear")
            do {
                _ = try Subprocess.run(Fixed.shell, [script.path], stdin: nil, env: env, setsid: true)
            } catch {
                preconditionFailure("the login script did not run: \(error)")
            }
        }
        try during()
    }
}

/// Waits until `done` holds, for `Fixed.settleLimit` at most.
func until(_ what: String, _ done: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let end = clock.now + Fixed.settleLimit
    while try !done() {
        try #require(clock.now < end, "timed out waiting for \(what)")
        try await Task.sleep(for: Fixed.pollStep)
    }
}

/// The value of `task`, cancelled past `Fixed.settleLimit`: an add whose
/// login never reports fails the test instead of hanging it.
func finish<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
    let timer = Task {
        try await Task.sleep(for: Fixed.settleLimit)
        task.cancel()
    }
    defer { timer.cancel() }
    return try await task.value
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
/// Tests that use the Keychain run in parallel; one at a time may create it.
let keychainGate = NSLock()

func ensureKeychain() throws {
    try keychainGate.withLock {
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

/// Anthropic's usage answer: session and week used, plus an Opus weekly window
/// and the `resets` blocks.
func claudeUsage(session: Int, week: Int, opus: Int? = nil, resets: String = "") -> String {
    let model = opus.map {
        #","limits":[{"kind":"weekly","percent":\#($0),"resets_at":"\#(Fixed.weekReset)","scope":{"model":{"display_name":"Opus"}}}]"#
    } ?? ""
    return #"{"five_hour":{"utilization":\#(session),"resets_at":"\#(Fixed.sessionReset)"},"#
        + #""seven_day":{"utilization":\#(week),"resets_at":"\#(Fixed.weekReset)"}\#(model)\#(resets)}"#
}

/// A `cedar_ember` block whose next grant, `grant-1`, has `left` resets; an
/// earlier grant is spent.
func cedarBlock(left: Int) -> String {
    #","cedar_ember":{"eligible":true,"next_grant_id":"grant-1","grants":["#
        + #"{"id":"grant-0","label":"Launch","resets_total":1,"resets_left":0,"usable_now":false,"paused":false},"#
        + #"{"id":"grant-1","label":"Welcome","resets_total":3,"resets_left":\#(left),"usable_now":true,"paused":false}]}"#
}

/// A `juniper_tide` block: one reset a week, `available` now or not.
func juniperBlock(available: Bool) -> String {
    #","juniper_tide":{"eligible":true,"available":\#(available),"next_available_at":null,"resets_per_week":1}"#
}

/// ChatGPT's usage answer: a 5-hour and a 7-day window, and `credits` limit
/// resets when given.
func codexUsage(session: Int, week: Int, credits: Int? = nil) -> String {
    let sessionAt = Fixed.now + Fixed.hour, weekAt = Fixed.now + Fixed.weekResetDays * Fixed.day
    let resets = credits.map { #","rate_limit_reset_credits":{"available_count":\#($0)}"# } ?? ""
    return #"{"rate_limit":{"primary_window":{"used_percent":\#(session),"limit_window_seconds":18000,"reset_at":\#(sessionAt)},"#
        + #""secondary_window":{"used_percent":\#(week),"limit_window_seconds":604800,"reset_at":\#(weekAt)}}\#(resets)}"#
}

func windows(session: Int, week: Int) -> [Limit] {
    [Limit(label: "Session (5-hour)", percent: session, resetsAt: Fixed.sessionReset),
     Limit(label: "Weekly (7-day)", percent: week, resetsAt: Fixed.weekReset)]
}

func probed(_ limits: [Limit], resets: ResetOffer? = nil) -> UsageRecord {
    UsageRecord(fetchedAt: Fixed.now, state: .ok, note: "", limits: limits, resets: resets)
}

/// A request body's members, which must all be strings.
func members(_ body: Data?) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: try #require(body))
}

// MARK: - App model

@MainActor @Test func appModelListsRowsAndSwitches() async throws {
    let w = try World(keychainService: Fixed.noKeychain)
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (backend, ay, by) = try codexPair(w)
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

/// Clicking the account a switch left would do nothing while the rows still
/// mark it active, so the panel stays busy until the reread shows the switch,
/// also when that reread queues behind a read already in flight.
@MainActor @Test(arguments: [false, true]) func appModelStaysBusyUntilTheSwitchShows(queued: Bool) async throws {
    let w = try World(keychainService: Fixed.noKeychain)
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (core, ay, by) = try codexPair(w)
    let gate = Gate(shut: false)
    let model = AppModel(connect: { GatedBackend(core: core, gate: gate) })
    model.start()
    try await settle(model)

    gate.close()
    if queued {
        model.refresh(force: true)
        try await poll("a status read in flight") { gate.held > 0 }
    }
    model.use(.codex, by)
    try await poll("the switch") { model.message == "Codex: now b@y" }
    #expect(model.busy)
    #expect(activeRow(model, .codex) == ay)

    gate.open()
    try await settle(model)
    #expect(activeRow(model, .codex) == by)
    #expect(model.message == "Codex: now b@y")
}

@MainActor @Test func appModelRetriesFromTheKeyboard() async throws {
    let w = try World(keychainService: Fixed.noKeychain)
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (core, ay, by) = try codexPair(w)
    let online = Gate(shut: true)
    let model = AppModel(connect: {
        guard online.isOpen else { throw KibaError.io(Fixed.offline) }
        return core
    })
    model.start()
    try await settle(model)
    #expect(model.availability == .failed(KibaError.io(Fixed.offline).reason))
    #expect(model.actions == [.retry])

    model.move(1)
    #expect(model.cursor == .retry)
    online.open()
    model.activate()
    try await settle(model)
    #expect(model.availability == .ready)
    #expect(model.error == "")
    #expect(model.sections.first { $0.id == .codex }?.accounts.map(\.name) == [ay, by])
}

@MainActor @Test func appModelConfirmsForgetFromTheKeyboard() async throws {
    let w = try World(keychainService: Fixed.noKeychain)
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (core, ay, by) = try codexPair(w)
    let model = AppModel(connect: { core })
    model.start()
    try await settle(model)

    model.ask(.forget, .codex, by)
    #expect(model.cursor == .keep(.codex, by))
    model.activate()
    #expect(model.confirming == nil)
    #expect(model.cursor == .use(.codex, by))

    model.ask(.forget, .codex, by)
    model.move(-1)
    #expect(model.cursor == .confirm(.codex, by))
    model.activate()
    try await settle(model)
    #expect(model.message == "Forgot b@y")
    #expect(model.sections.first { $0.id == .codex }?.accounts.map(\.name) == [ay])
}

/// A row offering limit resets carries its badge right after it in the
/// cursor order; a row with none left has no badge.
@MainActor @Test func appModelListsResetBadgeAfterItsRow() async throws {
    let w = try World(keychainService: Fixed.noKeychain)
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (core, _, ay, by) = try codexOffers(w, [])
    let model = AppModel(connect: { core })

    model.start()
    try await settle(model)
    #expect(model.actions == [.add(.claude), .add(.codex), .use(.codex, ay), .use(.codex, by), .redeem(.codex, by), .usage])
}

/// The badge asks first: Keep and Escape back out without reaching the
/// provider; Reset spends one and the row shows the provider's new count.
@MainActor @Test func appModelConfirmsThenRedeemsAReset() async throws {
    let w = try World(keychainService: Fixed.noKeychain)
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (core, http, _, by) = try codexOffers(w, [
        answer(Status.ok, #"{"code":"reset"}"#),
        answer(Status.ok, codexUsage(session: 0, week: 45, credits: 1)),
    ])
    let model = AppModel(connect: { core })
    model.start()
    try await settle(model)

    model.trigger(.redeem(.codex, by))
    #expect(model.confirming == Choice(kind: .reset, provider: .codex, name: by))
    #expect(model.cursor == .keep(.codex, by))
    model.activate()
    #expect(model.confirming == nil)
    #expect(model.cursor == .redeem(.codex, by))
    model.activate()
    model.escape()
    #expect(model.confirming == nil)
    #expect(http.requests.isEmpty)

    model.activate()
    model.move(-1)
    #expect(model.cursor == .confirm(.codex, by))
    model.activate()
    #expect(model.message == "Resetting limit for b@y…")
    try await settle(model)
    #expect(model.message == "Limit reset for b@y")
    #expect(model.error == "")
    #expect(http.requests.map(\.url.absoluteString) == [Endpoint.codexConsume, Endpoint.codexUsage])
    let row = model.sections.first { $0.id == .codex }?.accounts.first { $0.name == by }
    #expect(row?.usage == probed(windows(session: 0, week: 45), resets: ResetOffer(count: 1, program: "", grant: "")))
}

/// A reset the provider refuses spends nothing and says why; the row's
/// badge goes with the last credit.
@MainActor @Test func appModelSaysWhyNoResetWasSpent() async throws {
    let w = try World(keychainService: Fixed.noKeychain)
    defer { #expect(throws: Never.self) { try w.remove() } }
    let (core, _, _, by) = try codexOffers(w, [
        answer(Status.ok, #"{"code":"no_credit"}"#),
        answer(Status.ok, codexUsage(session: 100, week: 45, credits: 0)),
    ])
    let model = AppModel(connect: { core })
    model.start()
    try await settle(model)

    model.trigger(.redeem(.codex, by))
    model.trigger(.confirm(.codex, by))
    try await settle(model)
    #expect(model.message == "No limit resets left for b@y")
    #expect(model.error == "")
    #expect(!model.actions.contains(.redeem(.codex, by)))
}

/// A Codex world where a@y is live and saved and b@y is saved, and the
/// `CoreBackend` over it; a switch probes both accounts once.
func codexPair(_ w: World) throws -> (CoreBackend, SlotName, SlotName) {
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
        runner: try w.runner(http, keychain: FakeKeychain(items: [:])))
    return (backend, ay, by)
}

/// A Codex world where a@y is live and saved with no limit reset left and
/// b@y is saved at its session limit with two, and the `CoreBackend` over it;
/// `answers` are what the provider says to a redeem and its re-probe.
func codexOffers(_ w: World, _ answers: [HTTPOutcome]) throws -> (CoreBackend, StubHTTP, SlotName, SlotName) {
    let (ay, by) = (try slot("a@y"), try slot("b@y"))
    let liveAuth = codexAuth("a@y", plan: "plus", account: "acct-a", tag: "ya")
    try w.writeCodex(liveAuth)
    try w.seed(.codex, ay, Identity(email: "a@y", plan: "plus", org: "acct-a"), login: liveAuth, profile: nil,
               usage: probed(windows(session: 20, week: 45), resets: ResetOffer(count: 0, program: "", grant: "")))
    try w.seed(.codex, by, Identity(email: "b@y", plan: "pro", org: "acct-b"),
               login: codexAuth("b@y", plan: "pro", account: "acct-b", tag: "yb"), profile: nil,
               usage: probed(windows(session: 100, week: 45), resets: ResetOffer(count: 2, program: "", grant: "")))
    let http = StubHTTP(answers)
    let backend = CoreBackend(
        switcher: w.switcher(http), reader: StatusReader(paths: w.paths, store: w.store),
        runner: try w.runner(http, keychain: FakeKeychain(items: [:])))
    return (backend, http, ay, by)
}

/// The name of the provider's row the panel marks active.
@MainActor func activeRow(_ model: AppModel, _ p: Provider) -> SlotName? {
    model.sections.first { $0.id == p }?.accounts.first(where: \.active)?.name
}

/// `CoreBackend` whose status reads wait at `gate`.
struct GatedBackend: Backend {
    let core: CoreBackend
    let gate: Gate

    func status() -> Snapshot {
        gate.pass()
        return core.status()
    }

    func use(_ p: Provider, _ n: SlotName) async throws {
        try await core.use(p, n)
    }

    func save(_ p: Provider) throws -> SlotName? {
        try core.save(p)
    }

    func forget(_ p: Provider, _ n: SlotName) throws {
        try core.forget(p, n)
    }

    func probeAll(_ p: Provider) async -> ProbeReport {
        await core.probeAll(p)
    }

    func add(_ p: Provider, expected: String?) async throws -> AddResult {
        try await core.add(p, expected: expected)
    }

    func redeem(_ p: Provider, _ n: SlotName) async throws -> ResetOutcome {
        try await core.redeem(p, n)
    }
}

/// A gate the test opens and shuts while the model's reads run on other
/// threads: `pass()` blocks while it is shut.
final class Gate: @unchecked Sendable {
    private let cond = NSCondition()
    private var shut: Bool
    private var waiting = 0

    init(shut: Bool) {
        self.shut = shut
    }

    var isOpen: Bool { cond.withLock { !shut } }

    /// Callers blocked in `pass()` now.
    var held: Int { cond.withLock { waiting } }

    func close() {
        cond.withLock { shut = true }
    }

    func open() {
        cond.withLock {
            shut = false
            cond.broadcast()
        }
    }

    func pass() {
        cond.withLock {
            waiting += 1
            while shut { cond.wait() }
            waiting -= 1
        }
    }
}

/// Waits until the model has no read or action in flight.
@MainActor func settle(_ model: AppModel) async throws {
    try await poll("the model to settle") { !model.busy && !model.refreshing }
}

/// Waits until `done` holds, failing after `Fixed.settleLimit`.
@MainActor func poll(_ what: String, _ done: () -> Bool) async throws {
    let clock = ContinuousClock()
    let end = clock.now + Fixed.settleLimit
    while !done() {
        try #require(clock.now < end, "timed out waiting for \(what)")
        try await Task.sleep(for: Fixed.pollStep)
    }
}
