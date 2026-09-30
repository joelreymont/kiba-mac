import Foundation

/// Reads a Claude login's usage windows and limit resets from Anthropic (kiba
/// `CLAUDE-PROBE`), and spends a reset on request. A saved login whose access
/// token has expired is refreshed first; the live login's token belongs to
/// Claude Code, so an expired live token is reported, never sent or
/// refreshed. Writes nothing: a refreshed document comes back for the
/// Switcher to store.
public struct ClaudeProbe: Sendable {
    private let http: any HTTPClient
    private let clock: Clock

    public init(http: any HTTPClient, clock: @escaping Clock) {
        self.http = http
        self.clock = clock
    }

    public func run(_ i: ProbeInput) async -> ProbeOutcome {
        let now = epochSeconds(clock())
        var doc = i.doc
        func done(_ state: UsageState, _ note: String, _ limits: [Limit] = [], _ resets: ResetOffer? = nil)
            -> ProbeOutcome
        {
            .record(UsageRecord(fetchedAt: now, state: state, note: note, limits: limits, resets: resets), doc: doc)
        }

        switch await fresh(doc, live: i.live, now: now) {
        case .ready(let ready): doc = ready
        case .stale(let state, let note): return done(state, note)
        }
        guard let token = accessToken(doc) else { return done(.error, ProbeNote.noAccess) }
        let got = await http.send(.get(Endpoint.usage, bearer: token, agent: Endpoint.agent, extra: Endpoint.beta))
        guard case .response(let r) = got else { return done(.error, ProbeNote.unreachable(Note.usage)) }
        switch r.status {
        case HTTPStatus.ok:
            guard let body = JSONFields(r.body) else { return done(.error, ProbeNote.unreadable(Note.usage)) }
            return done(.ok, "", limits(body), resets(body))
        case HTTPStatus.unauthorized:
            return done(.expired, Note.rejected)
        case HTTPStatus.forbidden where Self.noPlan(r.body):
            return done(.unsubscribed, Note.unsubscribed)
        case HTTPStatus.tooManyRequests:
            return done(.error, Note.throttled)
        default:
            return done(.error, ProbeNote.answered(Note.usage, r.status))
        }
    }

    /// The usage endpoint's 403 for an organization whose plan does not
    /// allow Claude Code's OAuth: a lapsed subscription answers so, while
    /// the token document still claims the old plan.
    private static func noPlan(_ body: Data) -> Bool {
        JSONFields(body)?.obj(Fail.error)?.obj(Fail.details)?.str(Fail.code) == Fail.noOAuth
    }

    /// Spends one limit reset of `offer` for the organization `org`. A saved
    /// login's token is refreshed when it has expired, or once when the reset
    /// endpoint rejects it; the live login's never is.
    func redeem(_ i: ProbeInput, offer: ResetOffer, org: String) async -> Redemption {
        let now = epochSeconds(clock())
        var doc = i.doc
        func failed(_ error: KibaError) -> Redemption { Redemption(doc: doc, result: .failure(error)) }

        guard !org.isEmpty else { return failed(.badJSON("\(ClaudeIdentity.Key.account).\(ClaudeIdentity.Key.org)")) }
        guard let body = resetBody(offer) else { return failed(.noResets(i.provider, i.name.raw)) }
        let url = Endpoint.organizations.appending(component: org).appending(component: Endpoint.resetPath)
        func send(_ doc: Data) async -> HTTPOutcome? {
            guard let token = accessToken(doc) else { return nil }
            return await http.send(.post(url, json: body, bearer: token, agent: Endpoint.agent, extra: Endpoint.beta))
        }

        switch await fresh(doc, live: i.live, now: now) {
        case .ready(let ready): doc = ready
        case .stale(_, let note): return failed(.remote(note))
        }
        // A token refreshed a moment ago earns no second refresh.
        let refreshed = doc != i.doc
        guard var got = await send(doc) else { return failed(.remote(ProbeNote.noAccess)) }
        if case .response(let r) = got, r.status == HTTPStatus.unauthorized, !refreshed {
            if i.live { return failed(.remote(Note.liveExpired)) }
            switch await renewed(doc, now: now) {
            case .ready(let ready): doc = ready
            case .stale(_, let note): return failed(.remote(note))
            }
            guard let again = await send(doc) else { return failed(.remote(ProbeNote.noAccess)) }
            got = again
        }
        return Redemption(doc: doc, result: Self.reply.outcome(got))
    }

    /// `doc` with an access token that has not expired: as saved, or, for a
    /// saved login, refreshed. The live login's token is Claude Code's to refresh.
    private func fresh(_ doc: Data, live: Bool, now: Int) async -> Fresh {
        guard let ms = JSONFields(doc)?.obj(Key.oauth)?.int(Key.expiresAt), ms > 0,
              ms / Time.msPerSecond < now + Time.margin
        else { return .ready(doc) }
        if live { return .stale(.expired, Note.liveExpired) }
        return await renewed(doc, now: now)
    }

    /// `doc` with its saved refresh grant spent. An account on hold is an
    /// `error`, not `expired`: the hold may lift, so the login stays saved.
    private func renewed(_ doc: Data, now: Int) async -> Fresh {
        guard let grant = JSONFields(doc)?.obj(Key.oauth)?.str(Key.refreshToken) else {
            return .stale(.expired, Note.noGrant)
        }
        switch await refresh(doc, grant: grant, now: now) {
        case .fresh(let refreshed): return .ready(refreshed)
        case .denied(let r):
            let said = Refusal(r.body)
            if Hold.statuses.contains(r.status), said.onHold {
                return .stale(.error, Note.onHold(Self.appeal(said.uri)))
            }
            guard r.refused else { return .stale(.error, ProbeNote.answered(Note.token, r.status)) }
            return .stale(.expired, Note.refused(said.detail(r.status)))
        case .failed(let note): return .stale(.error, note)
        }
    }

    /// `s` with each run of whitespace and control characters as one space,
    /// cut to `Note.detailMax` Unicode scalars ending in `Note.ellipsis`:
    /// scalars, not characters, so combining marks cannot stack past the bound.
    private static func oneLine(_ s: String) -> String {
        let words = s.split { c in
            c.isWhitespace || c.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
        }
        let line = words.joined(separator: " ").unicodeScalars
        guard line.count > Note.detailMax else { return String(line) }
        return String(Substring(line.prefix(Note.detailMax - 1))) + Note.ellipsis
    }

    /// `uri` when it is a plain https page on Anthropic's own hosts: no user,
    /// port or fragment, nothing outside `Hold.chars`, no trailing `.` or `?`,
    /// at most `Note.detailMax` characters. Else Claude Code's fallback page.
    private static func appeal(_ uri: String?) -> String {
        guard let uri, uri.count <= Note.detailMax, uri.hasPrefix(Hold.scheme), let last = uri.last,
              !Hold.trailing.contains(last)
        else { return Hold.restricted }
        let rest = uri.dropFirst(Hold.scheme.count)
        let host = rest.prefix { $0 != "/" && $0 != "?" }.lowercased()
        guard rest.unicodeScalars.allSatisfy({ Hold.chars.contains($0) }), !host.isEmpty,
              host.unicodeScalars.allSatisfy({ Hold.hostChars.contains($0) }),
              Hold.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return Hold.restricted }
        return uri
    }

    private func accessToken(_ doc: Data) -> String? {
        JSONFields(doc)?.obj(Key.oauth)?.str(Key.accessToken)
    }

    /// The request for `offer`'s program; nil for a program kiba does not know.
    private func resetBody(_ offer: ResetOffer) -> Data? {
        switch offer.program {
        case Reset.banked:
            return jsonObject([
                Reset.program: Reset.banked, Reset.grantID: offer.grant, Reset.requestID: UUID().uuidString,
            ])
        case Reset.weekly:
            return jsonObject([Reset.program: Reset.weekly])
        default:
            return nil
        }
    }

    /// Spends the saved refresh grant and splices the new pair into `doc`. A
    /// document that does not scan is reported before the grant is spent.
    private func refresh(_ doc: Data, grant: String, now: Int) async -> Renewal {
        let base: JSONDoc
        do {
            base = try JSONDoc(doc)
        } catch {
            return .failed(ProbeNote.failure(error))
        }
        let body: KeyValuePairs = [
            Wire.grantType: Wire.refreshGrant, Wire.refreshToken: grant, Wire.clientID: Endpoint.clientID,
        ]
        return await http.renew(Endpoint.token, grant: body, what: Note.token) { answer in
            guard let access = answer.str(Wire.accessToken) else { return nil }
            var next = try base.setting(Key.oauth, Key.accessToken, to: jsonString(access))
            if let fresh = answer.str(Wire.refreshToken) {
                next = try next.setting(Key.oauth, Key.refreshToken, to: jsonString(fresh))
            }
            if let ms = expiry(now, answer.int(Wire.expiresIn)) {
                next = try next.setting(Key.oauth, Key.expiresAt, to: jsonNumber(ms))
            }
            if let ms = expiry(now, answer.int(Wire.refreshExpiresIn)) {
                next = try next.setting(Key.oauth, Key.refreshExpiresAt, to: jsonNumber(ms))
            }
            return next
        }
    }

    /// Epoch milliseconds `secs` after `now`; nil when `secs` is absent, not
    /// positive, or too large to represent.
    private func expiry(_ now: Int, _ secs: Int?) -> Int? {
        guard let secs, secs > 0 else { return nil }
        let (at, late) = now.addingReportingOverflow(secs)
        let (ms, huge) = at.multipliedReportingOverflow(by: Time.msPerSecond)
        return late || huge ? nil : ms
    }

    /// Session, then Weekly (`seven_day_oauth_apps`, else `seven_day`), then
    /// every model-scoped window. A window without a reading is left out.
    private func limits(_ body: JSONFields) -> [Limit] {
        var out: [Limit] = []
        if let s = bucket(body.obj(Usage.fiveHour), WindowLabel.session) { out.append(s) }
        let apps = bucket(body.obj(Usage.weekApps), WindowLabel.weekly)
        if let w = apps ?? bucket(body.obj(Usage.week), WindowLabel.weekly) { out.append(w) }
        for entry in body.objs(Usage.limits) {
            guard let model = entry.obj(Usage.scope)?.obj(Usage.model)?.str(Usage.displayName), !model.isEmpty,
                  let pct = usedPercent(entry.num(Usage.percent))
            else { continue }
            let label = scoped(model, kind: entry.str(Usage.kind) ?? "")
            out.append(Limit(label: label, percent: pct, resetsAt: entry.str(Usage.resetsAt) ?? ""))
        }
        return out
    }

    /// The banked grant to spend next, else the weekly reset; nil when the
    /// answer offers neither.
    private func resets(_ body: JSONFields) -> ResetOffer? {
        if let banked = body.obj(Reset.banked), banked.bool(Reset.eligible) == true,
           let next = banked.str(Reset.nextGrant),
           let grant = banked.objs(Reset.grants).first(where: { $0.str(Reset.id) == next }),
           let left = grant.int(Reset.left)
        {
            return ResetOffer(count: left, program: Reset.banked, grant: next)
        }
        guard let weekly = body.obj(Reset.weekly), weekly.bool(Reset.eligible) == true else { return nil }
        let count = weekly.bool(Reset.available) == true ? Reset.weeklyGrant : 0
        return ResetOffer(count: count, program: Reset.weekly, grant: "")
    }

    /// A `{utilization, resets_at}` bucket as the window `label`.
    private func bucket(_ b: JSONFields?, _ label: String) -> Limit? {
        guard let b, let pct = usedPercent(b.num(Usage.utilization)) else { return nil }
        return Limit(label: label, percent: pct, resetsAt: b.str(Usage.resetsAt) ?? "")
    }

    /// `<model> Weekly`, `<model> Session`, or the bare model name.
    private func scoped(_ model: String, kind: String) -> String {
        if kind.hasPrefix(Usage.weeklyKind) { return "\(model) \(Usage.weeklyWord)" }
        if Usage.sessionKinds.contains(where: kind.hasPrefix) { return "\(model) \(Usage.sessionWord)" }
        return model
    }

    private enum Endpoint {
        /// The flags ask for both reset blocks, as Claude Code does.
        static let usage = URL(
            string: "https://api.anthropic.com/api/oauth/usage?\(Reset.banked)=\(Reset.on)&\(Reset.atWall)=\(Reset.on)")!
        static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
        /// Followed by the organization UUID and `resetPath`.
        static let organizations = URL(string: "https://api.anthropic.com/api/organizations")!
        static let resetPath = "reset_rate_limits"
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        static let beta = ["anthropic-beta": "oauth-2025-04-20"]
        /// The usage endpoint offers limit resets only to Claude Code's own
        /// User-Agent (any other is `ineligible_reason: surface`; the CLI's
        /// other headers make no difference), so the usage and reset calls
        /// carry it, with the CLI version the check was made against.
        static let cliVersion = "2.1.282"
        static let agent = "claude-cli/\(cliVersion) (external, cli)"
    }

    /// Members of the saved credentials document.
    private enum Key {
        static let oauth = "claudeAiOauth"
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
        static let expiresAt = "expiresAt"
        static let refreshExpiresAt = "refreshTokenExpiresAt"
    }

    /// Members of the token endpoint's request and answer.
    private enum Wire {
        static let grantType = "grant_type"
        static let refreshGrant = "refresh_token"
        static let refreshToken = "refresh_token"
        static let clientID = "client_id"
        static let accessToken = "access_token"
        static let expiresIn = "expires_in"
        static let refreshExpiresIn = "refresh_token_expires_in"
    }

    /// Members of the usage endpoint's answer.
    private enum Usage {
        static let fiveHour = "five_hour"
        static let weekApps = "seven_day_oauth_apps"
        static let week = "seven_day"
        static let utilization = "utilization"
        static let resetsAt = "resets_at"
        static let limits = "limits"
        static let scope = "scope"
        static let model = "model"
        static let displayName = "display_name"
        static let kind = "kind"
        static let percent = "percent"
        static let weeklyKind = "weekly"
        static let sessionKinds = ["five_hour", "session"]
        static let weeklyWord = "Weekly"
        static let sessionWord = "Session"
    }

    /// Members of an error answer.
    private enum Fail {
        static let error = "error"
        static let details = "details"
        static let code = "error_code"
        /// The organization has no plan Claude Code may use.
        static let noOAuth = "oauth_not_allowed_for_organization"
        static let type = "type"
        static let description = "error_description"
        static let uri = "error_uri"
    }

    /// Anthropic's on-hold refusal and its appeal page, as Claude Code 2.1.285 reads them.
    private enum Hold {
        static let statuses = HTTPStatus.refusals + [HTTPStatus.forbidden]
        static let codes = ["invalid_grant", "access_denied"]
        static let description = "account_on_hold"
        /// Claude Code's page when the answer names none kiba trusts.
        static let restricted = "https://claude.ai/restricted"
        static let scheme = "https://"
        /// An appeal page's host is one of these or a subdomain.
        static let hosts = ["claude.ai", "anthropic.com"]
        static let hostChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        /// Every character an appeal page may spell after the scheme: no `@`, `:` or `#`.
        static let chars = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._~%-?=&")
        static let trailing: [Character] = [".", "?"]
    }

    /// A token endpoint's error answer as Claude Code reads it.
    private struct Refusal {
        /// `error` when it is a string, else `error.type`; "" when absent.
        let code: String
        /// `error_description`; "" when absent.
        let description: String
        let uri: String?

        init(_ body: Data) {
            let fields = JSONFields(body)
            code = fields?.str(Fail.error) ?? fields?.obj(Fail.error)?.str(Fail.type) ?? ""
            description = fields?.str(Fail.description) ?? ""
            uri = fields?.str(Fail.uri)
        }

        var onHold: Bool { Hold.codes.contains(code) && description == Hold.description }

        /// `<status> <code>: <description>` on one line, absent parts left out.
        func detail(_ status: Int) -> String {
            var out = String(status)
            if !code.isEmpty { out += " \(code)" }
            if !description.isEmpty { out += ": \(description)" }
            return ClaudeProbe.oneLine(out)
        }
    }

    /// Names in the limit-reset exchange, as Claude Code's parser reads them:
    /// the usage query flags and answer blocks, and the reset request and answer.
    private enum Reset {
        /// Banked grants: both the usage flag and block, and the program.
        static let banked = "cedar_ember"
        /// One reset a week: the block and the program.
        static let weekly = "juniper_tide"
        /// Asks the usage endpoint for `juniper_tide`.
        static let atWall = "at_wall"
        static let on = "1"
        static let eligible = "eligible"
        static let grants = "grants"
        static let id = "id"
        static let left = "resets_left"
        static let nextGrant = "next_grant_id"
        static let available = "available"
        /// Resets the weekly program offers while one is available.
        static let weeklyGrant = 1
        static let program = "program"
        static let grantID = "grant_id"
        static let requestID = "request_id"
        static let result = "result"
        static let words: [String: ResetOutcome] = [
            "reset": .reset, "already_used": .alreadyUsed, "not_limited": .notLimited, "cooldown": .cooldown,
            "ineligible": .ineligible, "unavailable": .unavailable,
        ]
    }

    private static let reply = ResetReply(
        field: Reset.result, words: Reset.words, what: Note.reset, rejected: Note.rejected, throttled: Note.resetThrottled)

    private enum Time {
        static let msPerSecond = 1000
        /// A token this close to expiring, in seconds, counts as expired.
        static let margin = 60
    }

    private enum Note {
        static let usage = "Anthropic's usage endpoint"
        static let token = "Anthropic's token endpoint"
        static let reset = "Anthropic's reset endpoint"
        static let liveExpired = "access token expired; Claude Code refreshes it on its next run"
        static let noGrant = "access token expired and no refresh token is saved; log in again"
        /// The longest server-supplied text a note carries.
        static let detailMax = 120
        static let ellipsis = "…"
        static let rejected = "login rejected by Anthropic; log in again"
        static let throttled = "Anthropic is rate limiting usage checks; try again later"
        static let unsubscribed = "no plan for Claude Code: Anthropic does not allow this organization's OAuth login"
        static let resetThrottled = "Anthropic is rate limiting limit resets; try again later"

        static func refused(_ detail: String) -> String {
            "access token expired and the refresh was refused (\(detail)); log in again"
        }

        static func onHold(_ url: String) -> String {
            "account on hold and cannot use Claude Code; view details or appeal at \(url)"
        }
    }
}
