import Foundation

/// Who a login belongs to. `plan` and `org` are "" when the login does not say.
public struct Identity: Equatable, Sendable {
    public var email: String
    public var plan: String
    public var org: String

    public init(email: String, plan: String, org: String) {
        self.email = email
        self.plan = plan
        self.org = org
    }
}

/// Claude Code logins: the `oauthAccount` object names the account, the
/// credentials document carries the plan.
public enum ClaudeIdentity {
    enum Key {
        static let account = "oauthAccount"
        static let email = "emailAddress"
        static let org = "organizationUuid"
        static let oauth = "claudeAiOauth"
        static let plan = "subscriptionType"
        static let creds = "credentials"
    }

    /// A saved `oauthAccount` object on its own; plan is "".
    static func fromOAuthAccount(_ obj: Data) throws -> Identity {
        try named(JSONFields(obj, what: Key.account))
    }

    /// The live config's top-level `oauthAccount` object plus the credentials'
    /// plan. Only that object's bytes are decoded: the rest of `.claude.json` is
    /// Claude Code's, and the identity must come from the very bytes
    /// `ClaudeLive.save` copies.
    static func fromLive(config: Data, creds: Data) throws -> Identity {
        var id = try fromOAuthAccount(profile(config))
        id.plan = planFromCreds(creds)
        return id
    }

    /// The exact bytes of the config's top-level `oauthAccount` object.
    static func profile(_ config: Data) throws -> Data {
        let doc = try JSONDoc(config)
        guard let span = doc.objectSpan(Key.account) else { throw KibaError.badJSON(Key.account) }
        return doc.data.subdata(in: span)
    }

    /// `claudeAiOauth.subscriptionType`; "" when absent or unreadable.
    static func planFromCreds(_ creds: Data) -> String {
        guard let obj = try? JSONFields(creds, what: Key.creds) else { return "" }
        return obj.obj(Key.oauth)?.str(Key.plan) ?? ""
    }

    private static func named(_ obj: JSONFields) throws -> Identity {
        guard let email = obj.str(Key.email), !email.isEmpty else {
            throw KibaError.badJSON("\(Key.account).\(Key.email)")
        }
        return Identity(email: email, plan: "", org: obj.str(Key.org) ?? "")
    }
}

/// Codex logins: `auth.json` names the account in the `tokens.id_token` JWT
/// claims, or holds only an API key.
public enum CodexIdentity {
    private enum Key {
        static let tokens = "tokens"
        static let idToken = "id_token"
        static let apiKey = "OPENAI_API_KEY"
        static let email = "email"
        static let claims = "https://api.openai.com/auth"
        static let plan = "chatgpt_plan_type"
        static let org = "chatgpt_account_id"
    }

    private static let keyLogin = Identity(email: "api-key", plan: "apikey", org: "")
    private static let tokenPath = "\(Key.tokens).\(Key.idToken)"
    private static let dot = UInt8(ascii: ".")
    private static let jwtParts = 3   // header.payload.signature

    static func fromAuth(_ auth: Data) throws -> Identity {
        let doc = try JSONFields(auth, what: tokenPath)
        guard let jwt = doc.obj(Key.tokens)?.str(Key.idToken) else {
            guard hasKey(doc) else { throw KibaError.badJSON(tokenPath) }
            return keyLogin
        }
        let body = try JSONFields(Base64URL.decode(payload(jwt), what: tokenPath), what: tokenPath)
        guard let email = body.str(Key.email), !email.isEmpty else { throw KibaError.badJSON("\(Key.idToken).\(Key.email)") }
        let info = body.obj(Key.claims)
        return Identity(email: email, plan: info?.str(Key.plan) ?? "", org: info?.str(Key.org) ?? "")
    }

    /// `OPENAI_API_KEY` is a non-empty string, whatever `tokens` holds.
    static func isAPIKey(_ auth: Data) -> Bool {
        guard let doc = try? JSONFields(auth, what: tokenPath) else { return false }
        return hasKey(doc)
    }

    private static func hasKey(_ doc: JSONFields) -> Bool {
        !(doc.str(Key.apiKey) ?? "").isEmpty
    }

    /// The bytes between the first two dots; dots are split as bytes, so a
    /// combining mark after one cannot hide it.
    private static func payload(_ jwt: String) throws -> Substring {
        let parts = jwt.utf8.split(separator: dot, maxSplits: jwtParts - 1, omittingEmptySubsequences: false)
        guard parts.count == jwtParts else { throw KibaError.badJSON(tokenPath) }
        return Substring(parts[1])
    }
}
