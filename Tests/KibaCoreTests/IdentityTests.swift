import Foundation
import Testing
@testable import KibaCore

@Suite struct ClaudeIdentityTests {
    static let noEmail = KibaError.badJSON("oauthAccount.emailAddress")
    static let noAccount = KibaError.badJSON("oauthAccount")
    static let noCreds = KibaError.badJSON("credentials")

    static let account = #"""
        {"emailAddress": "a@x.com", "organizationUuid": "org-1",
         "organizationName": "Acme", "displayName": "A"}
        """#

    static let creds = #"""
        {"claudeAiOauth": {"accessToken": "at", "refreshToken": "rt",
          "expiresAt": 1900000000000, "scopes": ["user:inference"],
          "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}
        """#

    /// A live config with odd formatting, a nested `oauthAccount` under
    /// `projects` that must not be read, and the real one last.
    static func config(_ account: String) -> Data {
        Data("""
            {
              "numStartups" :3,"projects":{"/w":{"oauthAccount":{"emailAddress":"nested@x"},
              "note":"\\"oauthAccount\\": {\\"emailAddress\\": \\"string@x\\"}"}},
              "oauthAccount"  :  \(account)
            }
            """.utf8)
    }

    @Test func oauthAccountGivesEmailAndOrg() throws {
        let id = try ClaudeIdentity.fromOAuthAccount(Data(Self.account.utf8))
        #expect(id == Identity(email: "a@x.com", plan: "", org: "org-1"))
    }

    @Test func oauthAccountKeyOrderAndEscapes() throws {
        let doc = #"{"organizationUuid":"org-2","displayName":"Zoë","emailAddress":"zoë@x.com"}"#
        let id = try ClaudeIdentity.fromOAuthAccount(Data(doc.utf8))
        #expect(id == Identity(email: "zoë@x.com", plan: "", org: "org-2"))
    }

    @Test func oauthAccountOrgAbsentIsEmpty() throws {
        for org in ["", #","organizationUuid":null"#, #","organizationUuid":7"#, #","organizationUuid":{}"#] {
            let doc = #"{"emailAddress":"a@x.com""# + org + "}"
            #expect(try ClaudeIdentity.fromOAuthAccount(Data(doc.utf8)).org == "", "\(doc)")
        }
    }

    @Test func oauthAccountWithoutEmailThrows() {
        let docs = [
            #"{"organizationUuid":"org-1"}"#,
            #"{"emailAddress":null}"#,
            #"{"emailAddress":42}"#,
            #"{"emailAddress":["a@x.com"]}"#,
            #"{"displayName":"\"emailAddress\":\"a@x.com\""}"#,
            #"{"profile":{"emailAddress":"a@x.com"}}"#,
        ]
        for doc in docs {
            #expect(throws: Self.noEmail, "\(doc)") { try ClaudeIdentity.fromOAuthAccount(Data(doc.utf8)) }
        }
    }

    @Test func oauthAccountNotAnObjectThrows() {
        for doc in ["", "not json", "[]", #""a@x.com""#, "null", #"{"emailAddress":"a@x.com""#] {
            #expect(throws: Self.noAccount, "\(doc)") { try ClaudeIdentity.fromOAuthAccount(Data(doc.utf8)) }
        }
    }

    @Test func liveReadsTopLevelAccountAndPlan() throws {
        let id = try ClaudeIdentity.fromLive(config: Self.config(Self.account), creds: Data(Self.creds.utf8))
        #expect(id == Identity(email: "a@x.com", plan: "max", org: "org-1"))
    }

    @Test func liveAccountMissingThrows() {
        let creds = Data(Self.creds.utf8)
        for value in ["null", #""a@x.com""#, "[]", "1"] {
            #expect(throws: Self.noAccount, "\(value)") {
                try ClaudeIdentity.fromLive(config: Self.config(value), creds: creds)
            }
        }
        let absent = Data(#"{"projects":{"/w":{"oauthAccount":{"emailAddress":"nested@x"}}}}"#.utf8)
        #expect(throws: Self.noAccount) { try ClaudeIdentity.fromLive(config: absent, creds: creds) }
        for doc in ["", "[]", "not json"] {
            #expect(throws: Self.noAccount, "\(doc)") {
                try ClaudeIdentity.fromLive(config: Data(doc.utf8), creds: creds)
            }
        }
    }

    @Test func liveAccountWithoutEmailThrows() {
        let config = Self.config(#"{"organizationUuid":"org-1","emailAddress":null}"#)
        #expect(throws: Self.noEmail) { try ClaudeIdentity.fromLive(config: config, creds: Data(Self.creds.utf8)) }
    }

    @Test func livePlanAbsentIsEmpty() throws {
        let config = Self.config(Self.account)
        for creds in ["{}", #"{"claudeAiOauth":null}"#, #"{"claudeAiOauth":{"accessToken":"at"}}"#,
                      #"{"claudeAiOauth":{"subscriptionType":null}}"#, #"{"subscriptionType":"max"}"#] {
            let id = try ClaudeIdentity.fromLive(config: config, creds: Data(creds.utf8))
            #expect(id == Identity(email: "a@x.com", plan: "", org: "org-1"), "\(creds)")
        }
    }

    @Test func liveCredsNotAnObjectThrows() {
        let config = Self.config(Self.account)
        for creds in ["", "not json", "[]", #""max""#] {
            #expect(throws: Self.noCreds, "\(creds)") {
                try ClaudeIdentity.fromLive(config: config, creds: Data(creds.utf8))
            }
        }
    }

    @Test func planFromCreds() {
        #expect(ClaudeIdentity.planFromCreds(Data(Self.creds.utf8)) == "max")
        #expect(ClaudeIdentity.planFromCreds(Data(#"{"claudeAiOauth":{"subscriptionType":"pro"}}"#.utf8)) == "pro")
        for creds in ["{}", #"{"claudeAiOauth":{}}"#, #"{"claudeAiOauth":"max"}"#,
                      #"{"claudeAiOauth":{"subscriptionType":3}}"#, #"{"subscriptionType":"max"}"#,
                      "", "not json", "[]"] {
            #expect(ClaudeIdentity.planFromCreds(Data(creds.utf8)) == "", "\(creds)")
        }
    }
}

@Suite struct CodexIdentityTests {
    static let noToken = KibaError.badJSON("tokens.id_token")
    static let noEmail = KibaError.badJSON("id_token.email")
    static let apiKey = Identity(email: "api-key", plan: "apikey", org: "")

    /// A JWT whose payload is `claims`, encoded independently of the decoder.
    static func jwt(_ claims: String) -> String {
        let head = Base64URLTests.encode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        return [head, Base64URLTests.encode(Data(claims.utf8)), "c2lnbmF0dXJl"].joined(separator: ".")
    }

    /// An auth.json with `tokens` and `OPENAI_API_KEY` as raw JSON values.
    static func auth(tokens: String, key: String = "null") -> Data {
        Data("""
            {"OPENAI_API_KEY": \(key), "auth_mode": "chatgpt",
             "last_refresh": "2026-09-01T00:00:00Z", "tokens": \(tokens)}
            """.utf8)
    }

    static func tokens(_ idToken: String) -> String {
        #"{"access_token":"at","account_id":"acct-9","id_token":"# + idToken + #","refresh_token":"rt"}"#
    }

    @Test func claimsGiveEmailPlanAndOrg() throws {
        let claims = #"{"email":"zoë.müller@例え.jp","name":"Zoë ~?>", "https://api.openai.com/auth":{"chatgpt_plan_type":"plus","chatgpt_account_id":"acct-9"}}"#
        let token = Self.jwt(claims)
        let payload = token.split(separator: ".")[1]
        // The fixture must exercise the url alphabet and an unpadded tail.
        #expect(payload.contains("-") && payload.contains("_") && payload.count % 4 != 0)
        let id = try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(token)\"")))
        #expect(id == Identity(email: "zoë.müller@例え.jp", plan: "plus", org: "acct-9"))
    }

    @Test func claimsAbsentAreEmpty() throws {
        let cases = [
            #"{"email":"a@x.com"}"#,
            #"{"email":"a@x.com","https://api.openai.com/auth":null}"#,
            #"{"email":"a@x.com","https://api.openai.com/auth":{}}"#,
            #"{"email":"a@x.com","chatgpt_plan_type":"plus","chatgpt_account_id":"acct-9"}"#,
        ]
        for claims in cases {
            let id = try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(Self.jwt(claims))\"")))
            #expect(id == Identity(email: "a@x.com", plan: "", org: ""), "\(claims)")
        }
        let partial = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-9","chatgpt_plan_type":5},"email":"a@x.com"}"#
        let id = try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(Self.jwt(partial))\"")))
        #expect(id == Identity(email: "a@x.com", plan: "", org: "acct-9"))
    }

    @Test func idTokenWinsOverAPIKey() throws {
        let doc = Self.auth(tokens: Self.tokens("\"\(Self.jwt(#"{"email":"a@x.com"}"#))\""), key: "\"sk-test\"")
        #expect(try CodexIdentity.fromAuth(doc) == Identity(email: "a@x.com", plan: "", org: ""))
        #expect(CodexIdentity.isAPIKey(doc))
    }

    @Test func apiKeyLoginWithoutIdToken() throws {
        for tokens in ["null", "{}", #"{"id_token":null}"#, #"{"id_token":7}"#, #""x.y.z""#, Self.tokens("null")] {
            let doc = Self.auth(tokens: tokens, key: "\"sk-test\"")
            #expect(try CodexIdentity.fromAuth(doc) == Self.apiKey, "\(tokens)")
        }
        let bare = Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8)
        #expect(try CodexIdentity.fromAuth(bare) == Self.apiKey)
    }

    @Test func neitherIdTokenNorAPIKeyThrows() {
        for key in ["null", #""""#, "1", #"["sk"]"#] {
            #expect(throws: Self.noToken, "\(key)") {
                try CodexIdentity.fromAuth(Self.auth(tokens: "null", key: key))
            }
        }
        for doc in ["", "not json", "[]", "{}", #"{"tokens":{"id_token":"a.b.c"}"#] {
            #expect(throws: Self.noToken, "\(doc)") { try CodexIdentity.fromAuth(Data(doc.utf8)) }
        }
    }

    @Test func malformedJWTThrows() {
        let body = Base64URLTests.encode(Data(#"{"email":"a@x.com"}"#.utf8))
        for token in ["", "abc", "a.\(body)", body, "."] {
            #expect(throws: Self.noToken, "\(token)") {
                try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(token)\""), key: "\"sk-test\""))
            }
        }
        let notObject = [Self.jwt("[1,2]"), Self.jwt(#""a@x.com""#), Self.jwt("not json"), "h..s"]
        for token in notObject {
            #expect(throws: Self.noToken, "\(token)") {
                try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(token)\"")))
            }
        }
        for token in ["h.!!!.s", "h.\(body)*.s", "h.Q.s", "h.Zm9vY.s"] {
            #expect(throws: Base64URLTests.bad, "\(token)") {
                try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(token)\"")))
            }
        }
    }

    @Test func payloadIsTheSecondSegment() throws {
        let first = Base64URLTests.encode(Data(#"{"email":"first@x.com"}"#.utf8))
        let second = Base64URLTests.encode(Data(#"{"email":"second@x.com"}"#.utf8))
        let token = "\(first).\(second).\(first).\(first)"
        let id = try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(token)\"")))
        #expect(id.email == "second@x.com")
        // A combining mark after the second dot does not merge it away.
        let marked = "\(first).\(second).\u{301}sig"
        let mid = try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(marked)\"")))
        #expect(mid.email == "second@x.com")
    }

    @Test func claimsWithoutEmailThrow() {
        let cases = [
            #"{"sub":"u-1"}"#,
            #"{"email":null}"#,
            #"{"email":1}"#,
            #"{"name":"\"email\":\"a@x.com\""}"#,
            #"{"https://api.openai.com/auth":{"email":"a@x.com","chatgpt_plan_type":"plus"}}"#,
        ]
        for claims in cases {
            #expect(throws: Self.noEmail, "\(claims)") {
                try CodexIdentity.fromAuth(Self.auth(tokens: Self.tokens("\"\(Self.jwt(claims))\""), key: "\"sk-test\""))
            }
        }
    }

    @Test func isAPIKey() {
        #expect(CodexIdentity.isAPIKey(Self.auth(tokens: "null", key: "\"sk-test\"")))
        #expect(CodexIdentity.isAPIKey(Data(#"{"OPENAI_API_KEY":"sk"}"#.utf8)))
        for key in ["null", #""""#, "1", "true", #"{"k":"sk"}"#] {
            #expect(!CodexIdentity.isAPIKey(Self.auth(tokens: "null", key: key)), "\(key)")
        }
        for doc in ["", "not json", "[]", "{}", #"{"tokens":{"OPENAI_API_KEY":"sk"}}"#] {
            #expect(!CodexIdentity.isAPIKey(Data(doc.utf8)), "\(doc)")
        }
    }
}
