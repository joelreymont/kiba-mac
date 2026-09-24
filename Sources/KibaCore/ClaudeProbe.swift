import Foundation

/// Reads a Claude login's usage windows from Anthropic (kiba `CLAUDE-PROBE`).
/// A saved login whose access token has expired is refreshed first; the live
/// login's token belongs to Claude Code, so an expired live token is reported,
/// never sent or refreshed. Writes nothing: a refreshed document comes back in
/// the outcome for the Switcher to store.
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
        func done(_ state: UsageState, _ note: String, _ limits: [Limit] = []) -> ProbeOutcome {
            .record(UsageRecord(fetchedAt: now, state: state, note: note, limits: limits), doc: doc)
        }

        let oauth = ProbeJSON(doc)?.obj(Key.oauth)
        if let ms = oauth?.int(Key.expiresAt), ms > 0, ms / Time.msPerSecond < now + Time.margin {
            if i.live { return done(.expired, Note.liveExpired) }
            guard let grant = oauth?.str(Key.refreshToken) else { return done(.expired, Note.noGrant) }
            switch await refresh(doc, grant: grant, now: now) {
            case .fresh(let refreshed): doc = refreshed
            case .refused: return done(.expired, Note.refused)
            case .failed(let note): return done(.error, note)
            }
        }

        guard let token = ProbeJSON(doc)?.obj(Key.oauth)?.str(Key.accessToken) else {
            return done(.error, ProbeNote.noAccess)
        }
        let got = await http.send(.get(Endpoint.usage, bearer: token, extra: [Endpoint.betaHeader: Endpoint.beta]))
        guard case .response(let r) = got else { return done(.error, ProbeNote.unreachable(Note.usage)) }
        switch r.status {
        case HTTPStatus.ok:
            guard let body = ProbeJSON(r.body) else { return done(.error, ProbeNote.unreadable(Note.usage)) }
            return done(.ok, "", limits(body))
        case HTTPStatus.unauthorized:
            return done(.expired, Note.rejected)
        case HTTPStatus.tooManyRequests:
            return done(.error, Note.throttled)
        default:
            return done(.error, ProbeNote.answered(Note.usage, r.status))
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
    private func limits(_ body: ProbeJSON) -> [Limit] {
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

    /// A `{utilization, resets_at}` bucket as the window `label`.
    private func bucket(_ b: ProbeJSON?, _ label: String) -> Limit? {
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
        static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        static let betaHeader = "anthropic-beta"
        static let beta = "oauth-2025-04-20"
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

    private enum Time {
        static let msPerSecond = 1000
        /// A token this close to expiring, in seconds, counts as expired.
        static let margin = 60
    }

    private enum Note {
        static let usage = "Anthropic's usage endpoint"
        static let token = "Anthropic's token endpoint"
        static let liveExpired = "access token expired; Claude Code refreshes it on its next run"
        static let noGrant = "access token expired and no refresh token is saved; log in again"
        static let refused = "access token expired and the refresh was refused; log in again"
        static let rejected = "login rejected by Anthropic; log in again"
        static let throttled = "Anthropic is rate limiting usage checks; try again later"
    }
}
