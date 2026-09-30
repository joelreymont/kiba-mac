import Foundation

/// Reads a Codex login's usage windows and limit-reset credits from ChatGPT
/// (kiba `CODEX-PROBE`), and spends a credit on request. A saved login whose
/// access token is rejected earns one refresh; the live login's token belongs
/// to the running codex and is never refreshed. Writes nothing: a refreshed
/// document comes back for the Switcher to store, and `.revoked` asks it to
/// remove the saved login.
public struct CodexProbe: Sendable {
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
        func result(_ got: HTTPOutcome) -> ProbeOutcome {
            guard case .response(let r) = got else { return done(.error, ProbeNote.unreachable(Note.usage)) }
            switch r.status {
            case HTTPStatus.ok:
                guard let body = JSONFields(r.body) else { return done(.error, ProbeNote.unreadable(Note.usage)) }
                return done(.ok, "", limits(body), resets(body))
            case HTTPStatus.unauthorized:
                return done(.expired, Note.rejected)
            case HTTPStatus.tooManyRequests:
                return done(.error, Note.throttled)
            default:
                return done(.error, ProbeNote.answered(Note.usage, r.status))
            }
        }

        let tokens = JSONFields(doc)?.obj(Key.tokens)
        if CodexIdentity.isAPIKey(doc), tokens?.str(Key.idToken) == nil { return done(.unknown, Note.apiKey) }
        guard let first = await usage(doc) else { return done(.error, ProbeNote.noAccess) }
        guard case .response(let r) = first, r.status == HTTPStatus.unauthorized else { return result(first) }
        if i.live { return done(.expired, Note.liveRejected) }
        switch await renewed(doc, rejection: r, now: now) {
        case .ready(let ready): doc = ready
        case .stale(.revoked, let note): return .revoked(note: note)
        case .stale(let state, let note): return done(state, note)
        }
        guard let again = await usage(doc) else { return done(.error, ProbeNote.noAccess) }
        return result(again)
    }

    /// Spends one limit-reset credit. A saved login whose access token is
    /// rejected earns one refresh; the live login's never does.
    func redeem(_ i: ProbeInput) async -> Redemption {
        let now = epochSeconds(clock())
        var doc = i.doc
        func failed(_ note: String) -> Redemption { Redemption(doc: doc, result: .failure(.remote(note))) }
        let body = jsonObject([Reset.requestID: UUID().uuidString])
        func send(_ doc: Data) async -> HTTPOutcome? {
            guard let token = accessToken(doc) else { return nil }
            return await http.send(
                .post(Endpoint.consume, json: body, bearer: token, agent: Endpoint.agent, extra: account(doc)))
        }

        guard var got = await send(doc) else { return failed(ProbeNote.noAccess) }
        if case .response(let r) = got, r.status == HTTPStatus.unauthorized {
            if i.live { return failed(Note.liveRejected) }
            switch await renewed(doc, rejection: r, now: now) {
            case .ready(let ready): doc = ready
            case .stale(_, let note): return failed(note)
            }
            guard let again = await send(doc) else { return failed(ProbeNote.noAccess) }
            got = again
        }
        return Redemption(doc: doc, result: Self.reply.outcome(got))
    }

    /// `doc` with its refresh grant spent after `rejection` refused its access
    /// token; `.stale(.revoked, …)` when the refresh is refused and the
    /// rejection said a later login revoked the token.
    private func renewed(_ doc: Data, rejection: HTTPResponse, now: Int) async -> Fresh {
        let revoked = JSONFields(rejection.body)?.obj(Wire.error)?.str(Wire.code) == Wire.tokenRevoked
        guard let grant = JSONFields(doc)?.obj(Key.tokens)?.str(Key.refreshToken) else {
            return .stale(.expired, Note.noGrant)
        }
        switch await refresh(doc, grant: grant, now: now) {
        case .fresh(let refreshed): return .ready(refreshed)
        case .denied(let r) where r.refused:
            return revoked ? .stale(.revoked, Note.revoked) : .stale(.expired, Note.refused)
        case .denied(let r): return .stale(.error, ProbeNote.answered(Note.token, r.status))
        case .failed(let note): return .stale(.error, note)
        }
    }

    /// GET the usage windows with `doc`'s access token; nil when it has none.
    private func usage(_ doc: Data) async -> HTTPOutcome? {
        guard let token = accessToken(doc) else { return nil }
        return await http.send(.get(Endpoint.usage, bearer: token, agent: Endpoint.agent, extra: account(doc)))
    }

    private func accessToken(_ doc: Data) -> String? {
        JSONFields(doc)?.obj(Key.tokens)?.str(Key.accessToken)
    }

    /// The `ChatGPT-Account-Id` header when `doc` names its account.
    private func account(_ doc: Data) -> [String: String] {
        guard let id = JSONFields(doc)?.obj(Key.tokens)?.str(Key.accountID), !id.isEmpty else { return [:] }
        return [Endpoint.accountHeader: id]
    }

    /// Spends the saved refresh grant and splices the new tokens and the refresh
    /// time into `doc`. A document that does not scan is reported before the
    /// grant is spent.
    private func refresh(_ doc: Data, grant: String, now: Int) async -> Renewal {
        let base: JSONDoc
        do {
            base = try JSONDoc(doc)
        } catch {
            return .failed(ProbeNote.failure(error))
        }
        let body: KeyValuePairs = [
            Wire.clientID: Endpoint.clientID, Wire.grantType: Wire.refreshGrant, Wire.refreshToken: grant,
        ]
        return await http.renew(Endpoint.token, grant: body, what: Note.token) { answer in
            guard let access = answer.str(Key.accessToken) else { return nil }
            var next = try base.setting(Key.tokens, Key.accessToken, to: jsonString(access))
            for key in [Key.refreshToken, Key.idToken] {
                if let value = answer.str(key) { next = try next.setting(Key.tokens, key, to: jsonString(value)) }
            }
            return try next.setting(Key.lastRefresh, to: jsonString(iso(now)))
        }
    }

    /// The primary and secondary windows, named from their length. A window
    /// without a reading is left out.
    private func limits(_ body: JSONFields) -> [Limit] {
        let rate = body.obj(Usage.rateLimit)
        return Usage.windows.compactMap { key in
            guard let w = rate?.obj(key), let pct = usedPercent(w.num(Usage.used)) else { return nil }
            let label = (w.int(Usage.length) ?? 0) <= Usage.sessionMax ? WindowLabel.session : WindowLabel.weekly
            let reset = w.int(Usage.resetAt).flatMap { $0 > 0 ? iso($0) : nil } ?? ""
            return Limit(label: label, percent: pct, resetsAt: reset)
        }
    }

    /// The credits the answer reports; nil when it says nothing about them.
    private func resets(_ body: JSONFields) -> ResetOffer? {
        guard let count = body.obj(Reset.credits)?.int(Reset.available) else { return nil }
        return ResetOffer(count: count, program: "", grant: "")
    }

    /// Epoch seconds as ISO 8601 UTC, such as `2026-09-24T12:00:00Z`.
    private func iso(_ secs: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(secs)).formatted(.iso8601)
    }

    private enum Endpoint {
        static let usage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        static let consume = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
        static let token = URL(string: "https://auth.openai.com/oauth/token")!
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let accountHeader = "ChatGPT-Account-Id"
        /// The ChatGPT backend calls name the Codex CLI, as codex itself does.
        static let agent = "codex-cli"
    }

    /// Members of `auth.json`; the token endpoint answers with the same names.
    private enum Key {
        static let tokens = "tokens"
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let idToken = "id_token"
        static let accountID = "account_id"
        static let lastRefresh = "last_refresh"
    }

    /// Members of the token request and of an error answer.
    private enum Wire {
        static let clientID = "client_id"
        static let grantType = "grant_type"
        static let refreshGrant = "refresh_token"
        static let refreshToken = "refresh_token"
        static let error = "error"
        static let code = "code"
        static let tokenRevoked = "token_revoked"
    }

    /// Members of the usage endpoint's answer.
    private enum Usage {
        static let rateLimit = "rate_limit"
        static let windows = ["primary_window", "secondary_window"]
        static let used = "used_percent"
        static let length = "limit_window_seconds"
        static let resetAt = "reset_at"
        /// The longest window, in seconds (six hours), still called a session.
        static let sessionMax = 21_600
    }

    /// Names in the limit-reset exchange, as codex's backend client reads them.
    private enum Reset {
        static let credits = "rate_limit_reset_credits"
        static let available = "available_count"
        static let requestID = "redeem_request_id"
        static let code = "code"
        static let words: [String: ResetOutcome] = [
            "reset": .reset, "nothing_to_reset": .notLimited, "no_credit": .noCredit, "already_redeemed": .alreadyUsed,
        ]
    }

    private static let reply = ResetReply(
        field: Reset.code, words: Reset.words, what: Note.reset, rejected: Note.rejected, throttled: Note.resetThrottled)

    private enum Note {
        static let usage = "OpenAI's usage endpoint"
        static let token = "OpenAI's token endpoint"
        static let reset = "OpenAI's reset endpoint"
        static let apiKey = "API-key login: no usage windows to read"
        static let liveRejected = "access token rejected; run codex once to refresh it"
        static let noGrant = "access token rejected and no refresh token is saved; log in again"
        static let refused = "access token rejected and the refresh was refused; log in again"
        static let revoked = "login revoked by a later `codex login`"
        static let rejected = "login rejected by OpenAI; log in again"
        static let throttled = "OpenAI is rate limiting usage checks; try again later"
        static let resetThrottled = "OpenAI is rate limiting limit resets; try again later"
    }
}
