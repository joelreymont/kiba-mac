# kiba-mac design

A native macOS menu bar app that switches the live Claude Code and Codex CLI
logins between saved copies and shows how much of each saved account's
allowance is left. It replaces the Linux kiba CLI plus Omarchy widget with one
Swift app: all account logic runs in-process, nothing shells out for status.

Behavioural source of truth: `~/Work/kiba` (README "How switching works",
"Usage per account", `src/*.f`, `plugin/kiba/Panel.qml`). Where this document
and kiba differ, this document wins; where it is silent, kiba's behaviour is
the spec.

## Layers

```
Package kiba-mac (SwiftPM, macOS 14+, Swift 6 language mode)
├── KibaCore   library: everything below the UI, no AppKit/SwiftUI
├── KibaApp    executable: NSStatusItem, popover, SwiftUI panel, AppModel
└── KibaCoreTests
```

Every external effect in KibaCore goes through a protocol so tests run in a
scratch directory with no network and no real Keychain:

| Effect            | Protocol / type      | Production                         | Tests                     |
|-------------------|----------------------|------------------------------------|---------------------------|
| paths             | `Paths(env:username:keychainService:)` | process env      | scratch HOME, `kiba-mac-test-<uuid>` base service |
| saved accounts    | `Store`              | SQLite at `paths.db`               | SQLite in the scratch store |
| secret bytes      | `SecretStore`        | `KeychainItem`, `FileSecret`       | `MemorySecret`, `FileSecret` |
| HTTP              | `HTTPClient`         | `URLSessionClient`                 | `StubHTTP`                |
| subprocess        | `Subprocess.run`     | posix_spawn                        | real, on throwaway inputs |
| clock             | `Clock` (`() -> Date`) | `Date.init`                      | frozen                    |
| terminal          | `TerminalLauncher`   | `open -a Terminal <file.command>`  | fake that runs the script |
| keychain items    | `Keychain`     | `KeychainTool` (`security`)        | fake                      |

## KibaCore

### Provider

```swift
public enum Provider: String, CaseIterable, Sendable, Codable {
  case claude, codex
  public var title: String        // "Claude Code" | "Codex"
  public var homeVar: String      // "CLAUDE_CONFIG_DIR" | "CODEX_HOME"
  public var site: String         // "claude.ai" | "chatgpt.com"
}
```

### Errors

```swift
public enum KibaError: Error, Equatable {
  case noLive(Provider)              // nothing to save
  case noAccount(Provider, String)   // no such saved account
  case badName(String)               // unsafe account name
  case badJSON(String)               // a login file lacks an expected field / is not JSON
  case loginFailed(Int32)            // provider login exited non-zero
  case loginProducedNothing(Provider)// login exited 0 but no credentials were found
  case loginRunning(Provider)        // an add for this provider is still waiting on its login
  case noCLI(String)                 // claude/codex not on PATH
  case mismatch(Provider, String)    // saved row names another account than its name
  case mixed                         // live Claude config and tokens name different accounts
  case superseded                    // another Claude install noted its own pending marker first
  case unrepaired(Provider, String)  // this install is still pending: nothing is probed or refreshed until a switch completes
  case orphanLive(URL)               // Claude creds exist but the config naming their account is missing
  case capacity(String)              // >9 logins under one email, doc over 4 MiB
  case unsafePath(URL)               // symlink chain longer than 8 hops or ends in a link
  case io(String)                    // any file error, with the path
  case db(String)                    // SQLite refused: "<operation>: <sqlite message>"
  case tool(String, Int32, String)   // subprocess name, exit status, stderr
  case noResets(Provider, String)    // redeem: the account's last probe offered no limit reset
  case remote(String)                // redeem: a provider endpoint refused or failed; the note is the reason
  case loginItem(String)             // Start at login: SMAppService refused, or cannot find the app
}
extension KibaError { public var reason: String }   // one-line, user-facing, no code
```

Every failure path throws; nothing logs and continues. Per-provider and
per-account isolation happens only in `StatusReader` and `Prober`, where the
error becomes that provider's `error` string or that account's usage `note`.

### Paths

```swift
public struct Paths: Sendable {
  public init(env: [String: String], username: String) throws   // io("HOME is not set") when HOME is missing or empty
  // store: $HOME/Library/Application Support/Kiba. Local to this Mac;
  // never shared. No kiba-specific variable: tests move HOME.
  public let store: URL
  public var db: URL                // store/kiba.db
  public var probe: URL             // store/probe
  public func loginRoot(_ p: Provider) -> URL            // store/probe/login-<provider>
  // HOME, CLAUDE_CONFIG_DIR, CODEX_HOME must be absolute when set:
  // a relative or `~` value throws io("<VAR> is not an absolute path: <value>");
  // nothing ever expands `~`.
  // live files; `root` selects a throwaway home for `add`
  public func claudeConfigDir(root: URL?) -> URL   // root/.claude | $CLAUDE_CONFIG_DIR | $HOME/.claude
  public func claudeConfigFile(root: URL?) -> URL  // <dir>/.claude.json when dir is explicit, else $HOME/.claude.json
  public func claudeCredsFile(root: URL?) -> URL   // <dir>/.credentials.json
  public func codexHome(root: URL?) -> URL         // root/.codex | $CODEX_HOME | $HOME/.codex
  public func codexAuthFile(root: URL?) -> URL     // <home>/auth.json
  public let username: String                      // Keychain account attribute
  // Claude Keychain services derive from a base, `keychainService:` in
  // init: Paths.claudeService = "Claude Code-credentials", tests pass
  // their own `kiba-mac-test-<uuid>`. service(dir) is Claude Code's
  // (2.1.282): base alone when CLAUDE_CONFIG_DIR is unset or empty, else
  // base + "-" + the first 8 lowercase hex digits of SHA-256 over the
  // UTF-8 of dir in NFC, the string as given (a trailing slash counts).
  public let keychainService: String               // service($CLAUDE_CONFIG_DIR): the live item
  public var loginService: String                  // service(claudeConfigDir(root: loginRoot(.claude)).path)
}
```

The app hands `Paths` its own environment, so the live item is the one
Claude Code keeps for the config dir the app was given: were it always the
bare service, a `CLAUDE_CONFIG_DIR` profile's identity would be paired with
the default profile's tokens.

### SlotName

A saved account name (`SlotName`) is an email, or `email #n` (n ≥ 2). Rules from kiba `NAME-OK?`:
1–127 bytes, no byte < 0x20, no 0x7F, no `/`, no leading `.`.
The suffix is the TRAILING `" #"` + ASCII digits (value > 0), the exact
inverse of how `liveName` builds names, so an email that itself contains
`" #"` still parses. `belongs(to: e)` is kiba's `NAME-FOR-EMAIL?`: raw == e, or
raw == e + `" #"` + positive digits. Equality and hashing are bytewise on the
spelling, the same as SQLite's default `BINARY` collation on the `name`
column, so a name is one row and one row is one name.

```swift
public struct SlotName: Hashable, Sendable, Comparable, CustomStringConvertible {
  public init?(_ raw: String)               // nil when NAME-OK? fails
  public let raw: String
  public var email: String                  // part before " #"
  public var suffix: Int?                   // n in "email #n", nil for the bare email
  public func belongs(to email: String) -> Bool
  public static func < (a, b) -> Bool       // different email parts: bytewise on the email part; same email: by suffix (bare = 1), then raw bytes
}
```

### PrivateFS

```swift
public enum PrivateFS {
  public static func writePrivate(_ data: Data, to url: URL) throws
  public static func ensurePrivateDir(_ url: URL) throws     // recursive mkdir 0700; existing dirs untouched
  public static func removeTree(_ url: URL) throws
  public static func writeTarget(_ url: URL) throws -> URL   // follows ≤ 8 symlink hops; throws unsafePath if still a link
  public static func isFile(_ url: URL) throws -> Bool       // regular file; false only for ENOENT/ENOTDIR, else io
                                                             // (another kind: io("<path> is a directory, not a regular file"))
  public static func exists(_ url: URL) -> Bool              // regular file; uninspectable reads as absent (PATH search)
  public static func isDir(_ url: URL) -> Bool
}
```

`writePrivate`: resolve the write target through the symlink chain (a live
file that is a symlink stays a symlink; the file behind it is replaced), open
a uniquely named temp (`<target>.<random>.tmp`, `O_EXCL`) in the same
directory, mode 0600, write all bytes, `F_FULLFSYNC` it, `rename` over the
target, then open the target's directory (following links) and
`F_FULLFSYNC` it, so the call returns only once the new file and its name
are on permanent storage (`fsync` alone leaves them in the drive's cache;
where the filesystem has no `F_FULLFSYNC`, `ENOTSUP`, `ENOTTY` or `EINVAL`,
plain `fsync` is the barrier, as SQLite falls back);
two concurrent writers can never disturb each other's temp. Any failure
before the rename removes the temp file and rethrows, leaving the target as
it was; a failed directory flush throws with the new file in place, not
known to survive a power loss. Never `Data.write(options: .atomic)`: it does
not control the mode.

### JSONDoc — byte-exact splicing

Login documents are rewritten by splicing bytes so every other key keeps its
exact bytes (kiba `SPLICE-CONFIG`, `CFG-REPLACE2`). A round-trip through
`JSONSerialization` is only allowed for the usage record, which kiba-mac
itself owns.

```swift
public struct JSONDoc {
  public init(_ data: Data) throws              // must be a JSON object, ≤ 4 MiB
  public func valueSpan(_ key: String) -> Range<Int>?                 // top-level key's value bytes
  public func objectSpan(_ key: String) -> Range<Int>?                // same, only when the value is an object
  public func valueSpan(_ key1: String, _ key2: String) -> Range<Int>? // one level down
  public func closingBrace() -> (index: Int, hasMembers: Bool)
  public func closingBrace(_ key: String) -> (index: Int, hasMembers: Bool)?  // of the object at top-level key
  public func replacing(_ span: Range<Int>, with: Data) throws -> JSONDoc   // badJSON when the result does not scan, capacity over 4 MiB
  public var data: Data
}
```

Construction checks the whole document as RFC 8259 JSON in one iterative
pass that nests arbitrarily deep: valid UTF-8, matched brackets, only JSON's
string escapes and no raw control byte in a string, JSON number grammar
(however large), and `true`/`false`/`null` spelled out; anything else is
`badJSON`. An escaped lone surrogate is valid JSON and passes. Values are
located, never decoded. Reading fields (`JSONFields`: `str`, `obj`, `num`,
`int`, …) runs the same scan over the same bytes and builds a tree whose
numbers keep their spelling, read as `Decimal` without a binary
floating-point step; `JSONDoc` only locates spans for writes. Both key
members by their decoded bytes (a lone surrogate as generalized UTF-8), so
keys Swift strings would merge (`é` composed and decomposed, two lone
surrogates) stay distinct: only keys equal in bytes repeat. A key the app
names is looked up by its UTF-8.

### Identity

```swift
public struct Identity: Equatable, Sendable { public var email: String; public var plan: String; public var org: String }

public enum ClaudeIdentity {
  static func fromOAuthAccount(_ obj: Data) throws -> Identity        // {emailAddress, organizationUuid}; plan ""
  static func profile(_ config: Data) throws -> Data                  // config[JSONDoc(config).objectSpan("oauthAccount")]; no span → badJSON("oauthAccount")
  // ClaudeLive.login() = fromOAuthAccount(profile(config)) with plan =
  // planFromCreds(creds). Only the span is decoded: .claude.json is Claude
  // Code's file and may hold values (a lone surrogate escape, a huge number)
  // that JSONSerialization rejects, and the identity must come from the very
  // bytes ClaudeLive.login copies.
  static func planFromCreds(_ creds: Data) -> String                   // "" when absent
}
public enum CodexIdentity {
  static func fromAuth(_ auth: Data) throws -> Identity
  // tokens.id_token → JWT payload (base64url, no padding) → email,
  // "https://api.openai.com/auth".chatgpt_plan_type (plan),
  // .chatgpt_account_id (org). No id_token but OPENAI_API_KEY →
  // Identity(email: "api-key", plan: "apikey", org: ""). Neither → badJSON.
  static func isAPIKey(_ auth: Data) -> Bool
}
```

`badJSON` when the email is missing or empty. Plan and org are "" when
absent. `Base64URL` (internal) accepts only the url alphabet with optional
trailing `=` padding (at most two, then end of text); anything else is
`badJSON` naming the field (`tokens.id_token`). Field reads on parsed
documents go through one internal reader, `JSONFields` (`init(_:what:)`,
`str`, `obj`, `int`, `bool`), shared by identity, live-login, and probe code.

### SecretStore

```swift
public protocol SecretStore: Sendable {
  func read() throws -> Data?     // nil when no item/file exists
  func write(_ data: Data) throws
  func remove() throws            // no-op when absent
}
public struct FileSecret: SecretStore { public init(url: URL) }            // read whole file; write via PrivateFS
public struct KeychainItem: SecretStore { public init(service: String, account: String) }
public final class MemorySecret: SecretStore { public init(_ data: Data?) }
```

`KeychainItem` drives `/usr/bin/security`, the same tool Claude Code uses, so
the item's ACL admits it: while the login keychain is unlocked and the ACL is
as Claude Code left it, no call triggers a Keychain prompt. A locked keychain
makes macOS ask for its password, and an ACL without the tool makes it ask to
allow access (`setsid` does not stop either dialog); the call waits for the
answer with no bound, and a refusal is `tool`:

- read: `security find-generic-password -a <account> -s <service> -w`;
  exit 44 (`errSecItemNotFound`) → nil; other non-zero → `tool`.
- write: `add-generic-password -U -a <account> -s <service> -X <hex>` as
  one command line on the stdin of `security -i`, spawned with
  `POSIX_SPAWN_SETSID`. (`-w` on stdin reads at most 128 bytes; a login is
  larger.) `security -i` cuts a line at 4096 bytes and still stores the
  cut secret, so a line that would not fit is instead run as the same
  command in argv, the way Claude Code itself writes a large credential;
  only then is the secret visible in the process list for the tool's run.
- remove: `security delete-generic-password -a … -s …`; exit 44 → no-op.

The live Claude credential store is chosen by existence, never by platform:

```swift
public enum ClaudeSecrets {
  public static func live(paths: Paths, root: URL?) -> SecretStore
  // FileSecret(<configDir>/.credentials.json) when that is a regular file,
  // else KeychainItem(paths.keychainService, paths.username): the item
  // Claude Code keeps for $CLAUDE_CONFIG_DIR (see Paths). Chosen again at
  // every read and write. Only a missing file (ENOENT, ENOTDIR) selects the
  // Keychain; one that cannot be inspected (EACCES, ELOOP, …) is io, and so
  // is another kind of file there (a directory, FIFO, socket, device),
  // named in the reason; nothing is read or written then.
}
```

### Subprocess

```swift
public enum Subprocess {
  public struct Result { public let status: Int32; public let stdout: Data; public let stderr: Data }
  public static func run(_ tool: URL, _ args: [String], stdin: Data?, env: [String: String]?, setsid: Bool) throws -> Result
  public static func find(_ name: String, path: String) -> URL?     // PATH lookup; noCLI when absent
}
```

posix_spawn with pipes; drains stdout/stderr concurrently; `setsid` sets
`POSIX_SPAWN_SETSID`. No `Foundation.Process` (it cannot set the session).

### Store

One SQLite database, `paths.db`, holds every saved account. No lock file,
no slot directories, no markers: a write transaction is the mutex and every
row is whole or absent.

```sql
PRAGMA user_version = 2;
CREATE TABLE IF NOT EXISTS account (
  provider TEXT NOT NULL,          -- "claude" | "codex"
  name     TEXT NOT NULL,          -- SlotName.raw
  email    TEXT NOT NULL,
  org      TEXT NOT NULL,          -- "" when unknown
  plan     TEXT NOT NULL,          -- "" when unknown
  login    BLOB NOT NULL,          -- Claude: credentials.json bytes; Codex: auth.json bytes
  profile  BLOB,                   -- Claude: the exact oauthAccount object bytes; Codex: NULL
  usage    TEXT,                   -- UsageRecord JSON (sorted keys); NULL until probed
  PRIMARY KEY (provider, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS live (
  provider  TEXT PRIMARY KEY,      -- row absent: nothing installed yet
  installed TEXT NOT NULL          -- name whose login is live
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS pending (
  provider TEXT PRIMARY KEY,       -- row absent: no install in flight
  name     TEXT NOT NULL,          -- name an unfinished install was writing
  owner    TEXT                    -- the claim of the install that noted it; NULL: noted by version 1
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS adding (
  provider TEXT PRIMARY KEY,       -- row absent: no add in flight
  live     BLOB                    -- the live Keychain item before the add's login; NULL: there was none
) WITHOUT ROWID;
```

```swift
public struct SavedLogin: Equatable, Sendable {
  public var name: SlotName
  public var identity: Identity      // email, org, plan (the plan column)
  public var login: Data
  public var profile: Data?
  public var usage: UsageRecord?
}

public struct LiveItem: Equatable, Sendable { public var bytes: Data? }   // nil: no item

public struct Store: Sendable {
  public init(paths: Paths) throws                 // mkdir store 0700; open/create db 0600; apply schema
  public func list(_ p: Provider) throws -> [SavedLogin]              // sorted by SlotName
  public func fetch(_ p: Provider, _ n: SlotName) throws -> SavedLogin?
  public func liveName(_ p: Provider, live: Identity) throws -> SlotName
  public func installed(_ p: Provider) throws -> SlotName?
  public func pending(_ p: Provider) throws -> SlotName?          // nil when no install is in flight
  public func adding(_ p: Provider) throws -> LiveItem?          // nil when no add is in flight
  public func write<T>(_ body: (Tx) throws -> T) throws -> T   // BEGIN IMMEDIATE … COMMIT; any throw rolls back and rethrows
}
public struct Claim: Equatable, Sendable { let owner: String }   // one install's hold on the pending marker
public final class Tx {                             // only inside `write`: closed when `body` ends
  public func put(_ p: Provider, _ s: SavedLogin) throws        // upsert; an existing row keeps its usage when s.usage is nil
  public func setLogin(_ p: Provider, _ n: SlotName, _ doc: Data) throws   // noAccount when absent
  public func setUsage(_ p: Provider, _ n: SlotName, _ u: UsageRecord) throws
  public func remove(_ p: Provider, _ n: SlotName) throws        // no-op when absent
  public func noteInstalled(_ p: Provider, _ n: SlotName) throws // upsert into live
  public func notePending(_ p: Provider, _ n: SlotName) throws -> Claim   // upsert into pending under a new owner (UUID)
  public func owns(_ p: Provider, _ c: Claim) throws -> Bool     // the marker is still c's
  public func clearPending(_ p: Provider, _ c: Claim) throws     // deletes c's marker; no-op once another replaced it
  public func noteAdding(_ p: Provider, _ i: LiveItem) throws    // upsert into adding
  public func clearAdding(_ p: Provider) throws                  // no-op when absent
}
```

`Store` holds only the database URL: every call opens a connection
(`sqlite3_open_v2` with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
SQLITE_OPEN_NOFOLLOW`, `chmod 0600` after creation), sets
`PRAGMA busy_timeout = 5000` and `PRAGMA journal_mode = WAL`, runs, and
closes. So the value is `Sendable` without a mutex and a status read costs
two queries. Every SQLite failure is `db("<op>: <sqlite3_errmsg>")`. Rows
decode through `SlotName(raw)`; a raw that fails `NAME-OK?` is `badName`
(nothing in kiba-mac can write one, so it means the file was edited by hand).
A `usage` column that fails to decode yields
`UsageRecord(fetchedAt: 0, state: .unknown, note: "usage record is unreadable; refresh usage", limits: [])`.
`write` bodies may do file and Keychain work: the transaction is the
cross-process mutex for a switch, held only for the duration of the body.
The `Tx` ends with the body, committed or rolled back: kept past it, every
call throws `db("<op>: transaction is closed")` instead of running outside
the transaction.

`init` applies the schema in one `write`. A version 1 store (its `pending`
table has no `owner`: `pragma_table_info` finds none) gains the column by
`ALTER TABLE pending ADD COLUMN owner TEXT`; every row is kept, and a marker
it holds, owned by no install, stays until an install replaces it.

`liveName` (kiba `LIVE-NAME`): candidates `email`, `email #2` … `email #9`.
For each: no row → first free candidate remembered; row exists and its org
equals the live org (both empty counts as equal; one empty does not) →
return that row's name. Return the first free; none → `capacity`.

### Claude live login

```swift
public struct ClaudeLive {
  public init(paths: Paths, store: Store, secrets: SecretStore)   // secrets = ClaudeSecrets.live(...)
  public func identity() throws -> Identity?     // nil when no creds; orphanLive when creds exist without a config
  func login() throws -> LoginRead?              // one read: identity, login = creds bytes, profile = exact oauthAccount object bytes; nil as identity
  public func install(_ n: SlotName) throws
  public func isMixed() throws -> Bool
}
```

`install` (kiba `CLAUDE-INSTALL`): `store.fetch` must return a row else
`noAccount`; its profile must be present and its email must belong to `n`
else `mismatch`; login must be an object with a `claudeAiOauth` object else
`badJSON`. Build the new config: existing config with the top-level
`oauthAccount` value replaced by the profile bytes (any value kind,
including `null`), or inserted before the closing brace (with a comma when
the object has members), or a new `{"oauthAccount":…}` when the file does not
exist. The checks, the read of the previous config and credential bytes and
of whether an install was pending, and the splice run in one `store.write`
that ends with `claim = tx.notePending(n)`, committed before either live
file changes. Then, in a second `store.write`: `tx.owns(claim)` else
`superseded` (another install noted its own marker since; this one writes
nothing and its preparation is dropped) → write config →
`secrets.write(login)` → `tx.noteInstalled(n)` → `tx.clearPending(claim)`.
Each file write returns only once it is on permanent storage (`PrivateFS`),
so the marker is never cleared ahead of the files it vouches for. When
either live write fails, the previous config bytes go back (the file is
removed when there was none) and the write's error is thrown. The marker is
cleared only when the live files are known to be the pair from before: the
config went back, the credentials read back as the bytes read before (a
failed write may still have replaced them), and no install was pending
before. Otherwise it stays: a config that cannot go back, credentials that
changed or cannot be read, or a repair of files an earlier install left
pending, which still disagree. A crash between the two live writes also
leaves it pending, and a pending install is mixed whatever the tokens are,
so a refresh by Claude Code cannot make the next save-back file one
account's tokens under another's name.

`isMixed` (kiba `CLAUDE-MIXED?`): the live login is read first, so
`orphanLive` propagates whether or not an install is pending. Then a
pending install → true. Else `installed` names row S and S exists and
there is a live login and the live config does NOT name S (email differs,
or both orgs known and differ) and the live creds bytes equal S's login
bytes → true. The next successful install clears it.

Reading the live login (`identity`, `save`, `isMixed`): no credentials → no
live login (nil). Credentials without a config → `orphanLive(config path)`:
the tokens are some account's, maybe a saved row's refresh token, and
nothing says whose, so no saved login is refreshed and the live credentials
are not replaced until the config names them. `Switcher.save`, `use` and
`redeem` throw it before writing anything, a pending install
notwithstanding: `use` never installs over orphan credentials, and the
marker stays. `probeAll` reports it as both
`saveBackError` and `providerError` and probes nothing; `StatusReader`
shows it as the provider's error. Codex is unchanged: a missing `auth.json`
is no credentials.

### Codex live login

```swift
public struct CodexLive {
  public init(paths: Paths, store: Store, root: URL? = nil)
  public func identity() throws -> Identity?     // nil when auth.json missing
  func login() throws -> LoginRead?              // one read: identity, login = live auth.json bytes, profile nil; nil as identity
  public func install(_ n: SlotName) throws      // fetch (noAccount); email must belong to n else mismatch; inside store.write: write live auth.json, noteInstalled
}
```

### Usage records

```swift
public struct Limit: Codable, Equatable, Sendable { public var label: String; public var percent: Int; public var resetsAt: String }
public enum UsageState: String, Codable, Sendable { case ok, expired, revoked, error, unknown, unsubscribed }
// unsubscribed: the login works, but the organization has no plan the CLI may use
public struct ResetOffer: Codable, Equatable, Sendable {
  public var count: Int              // resets available now
  public var program: String         // Claude: "cedar_ember" (banked grants) | "juniper_tide" (one per week); Codex: ""
  public var grant: String           // Claude cedar_ember: the grant to spend; else ""
}
public struct UsageRecord: Codable, Equatable, Sendable {
  public var fetchedAt: Int          // epoch seconds
  public var state: UsageState
  public var note: String
  public var limits: [Limit]
  public var resets: ResetOffer?     // nil: the provider said nothing about limit resets
}
```

`resets` is optional and encoded only when present, so a record stored
before limit resets were read decodes with `resets == nil`.

`percent` is the whole number USED (0…100+). Percent rounding: decode the
JSON number's spelling as `Decimal`, never through `Double`, and round with
`NSDecimalRound(.plain, scale 0)`.
Labels: `Session (5-hour)`, `Weekly (7-day)`, `<Model> Weekly` /
`<Model> Session` / `<Model>` for scoped windows. `resetsAt` is ISO 8601 or
"". The `usage` column is written through `JSONEncoder` (sorted keys);
`usageEncode`/`usageDecode` in `Usage.swift` are the only codec, and a
damaged column decodes to the unreadable record named under Store.

### HTTP

```swift
public struct HTTPRequest: Sendable { public var method: String; public var url: URL; public var headers: [String: String]; public var body: Data? }
public struct HTTPResponse: Sendable { public var status: Int; public var body: Data }
public enum HTTPOutcome: Sendable { case response(HTTPResponse); case unreachable(String) }
public protocol HTTPClient: Sendable { func send(_ r: HTTPRequest) async -> HTTPOutcome }
public struct URLSessionClient: HTTPClient { public init(timeout: TimeInterval = 20) }  // ephemeral session, no cookies, no cache, no redirects to other hosts
public final class StubHTTP: HTTPClient  // scripted responses, records requests
```

Every request sets `Accept: application/json` and `User-Agent: kiba` except
the usage and reset calls of both providers: the ChatGPT backend calls send
`User-Agent: codex-cli`, and the Claude ones send Claude Code's own
`claude-cli/<version> (external, cli)` (`ClaudeProbe.Endpoint.agent`, the
CLI version the check was made against). The Claude usage endpoint answers
every other User-Agent with `ineligible_reason: "surface"` in both reset
blocks, and the CLI's other headers (`x-app`, `anthropic-client-platform`,
`anthropic-client-version`) change nothing (checked 2026-09-25 with the
live login: the User-Agent alone turned `cedar_ember.eligible` true). The
token refresh keeps `kiba`. Builders: `HTTPRequest.get(url, bearer:, agent:, extra:)`,
`.post(url, json:, bearer:, agent:, extra:)` (adds `Content-Type:
application/json`), and `.post(url, json:)` for token grants, which carry
no bearer.

### Probing (port of sw-usage.f)

```swift
public struct ProbeInput { provider, name: SlotName, doc: Data /* the row's login bytes */, live: Bool }
public enum ProbeOutcome: Equatable { case record(UsageRecord, doc: Data /* possibly refreshed */); case revoked(note: String) }

public struct ClaudeProbe { init(http: HTTPClient, clock: Clock); func run(_ i: ProbeInput) async -> ProbeOutcome }
public struct CodexProbe  { same }
```

A probe never writes: a refreshed document comes back in `.record(_, doc:)`
and the Switcher persists it. The Switcher runs one operation per provider
at a time, so a refresh is never overtaken by a switch that makes the login
live; and it writes an outcome only while the row still holds the bytes the
probe read.

A pending Claude repair stops all Claude probes and refreshes until `use`
completes it: a failed install can leave one saved login's credentials
live under another's restored config, and a later failed repair can rename
the marker, so no saved name is known not to be live. `probeAll` probes
nothing and `redeem` refuses, both with `unrepaired(name)`. Only the probe
`LoginRunner` runs after an import goes on: it reads the login just signed
in, whose tokens are not the live ones.

Claude:
1. Expired = `claudeAiOauth.expiresAt/1000 < now + 60`. If expired: live →
   `expired` "access token expired; Claude Code refreshes it on its next
   run"; no `refreshToken` → `expired` "…no refresh token is saved; log in
   again"; else refresh: POST
   `https://platform.claude.com/v1/oauth/token` JSON
   `{grant_type:"refresh_token", refresh_token, client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`.
   200 → splice `accessToken`, `refreshToken` (if returned), `expiresAt =
   (now+expires_in)*1000`, `refreshTokenExpiresAt` (if
   `refresh_token_expires_in`) into `claudeAiOauth`, each added at the end of
   that object when the doc lacks it. 400/401 → `expired` "…the refresh
   was refused; log in again". Anything else / unreachable → `error`
   "Anthropic's token endpoint answered <code>" / "…could not be reached".
2. GET `https://api.anthropic.com/api/oauth/usage?cedar_ember=1&at_wall=1`
   (the flags ask for both reset blocks, as Claude Code 2.1.282 does; its
   `skip_spend=1` is omitted), `Authorization: Bearer`,
   `anthropic-beta: oauth-2025-04-20`, UA `claude-cli/<version> (external,
   cli)` (see HTTP: the reset blocks are empty for any other). 200 → limits: `five_hour` →
   Session; `seven_day_oauth_apps` else `seven_day` → Weekly (each bucket
   `{utilization, resets_at}`); then every `limits[]` entry with
   `scope.model.display_name` → `"<display_name> Weekly"` when `kind` starts
   with `weekly`, `"… Session"` for `five_hour`/`session`, bare name
   otherwise, `percent` from `percent`, reset from `resets_at`. State `ok`.
   Resets: `cedar_ember` `{eligible, grants[{id, label, resets_total,
   resets_left, usable_now, paused}], next_grant_id}` offers when `eligible`
   and the grant whose `id` is `next_grant_id` exists: count = its
   `resets_left`, program `cedar_ember`, grant = its id. Else `juniper_tide`
   `{eligible, available, next_available_at, resets_per_week}` offers when
   `eligible`: count = `available` ? 1 : 0, program `juniper_tide`, grant "".
   Neither → nil. The names come from Claude Code's parser and live in one
   constants enum, `Reset`.
   401 → `expired` "login rejected by Anthropic; log in again". 403 whose
   body's `error.details.error_code` is `oauth_not_allowed_for_organization`
   → `unsubscribed` "no plan for Claude Code: Anthropic does not allow this
   organization's OAuth login": the login works, but the organization has
   no plan Claude Code may use. A lapsed subscription answers so, while the
   token document still claims its old `subscriptionType`, so the saved plan
   is not shown for such a row (see Rows). 429 → `error`
   "Anthropic is rate limiting usage checks; try again later". Other →
   `error` "Anthropic's usage endpoint answered <code>". No `accessToken` →
   `error` "no access token saved".

Codex:
1. `OPENAI_API_KEY` present and no `tokens.id_token` → `unknown` "API-key
   login: no usage windows to read".
2. GET `https://chatgpt.com/backend-api/wham/usage`, Bearer
   `tokens.access_token`, `ChatGPT-Account-Id: tokens.account_id` (when
   present), UA `codex-cli`. 200 → `rate_limit.primary_window` and
   `secondary_window` `{used_percent, limit_window_seconds, reset_at}`:
   label Session when `limit_window_seconds ≤ 21600` else Weekly; `reset_at`
   epoch → ISO 8601 UTC. `rate_limit_reset_credits.available_count` N →
   `ResetOffer(count: N, program: "", grant: "")`; absent → nil (codex
   rust-v0.157.0 `backend-client/src/types.rs`). 401 on live → `expired`
   "access token rejected; run
   codex once to refresh it". 401 on saved → revokedFlag = body
   `error.code == "token_revoked"`; refresh: POST
   `https://auth.openai.com/oauth/token`
   `{client_id:"app_EMoamEEZ73f0CkXaXp7hrann", grant_type:"refresh_token", refresh_token}`;
   200 → splice `tokens.access_token`, `tokens.refresh_token`,
   `tokens.id_token` (each if returned), top-level `last_refresh` = ISO now
   into the doc, each added at the end of its object when absent; then GET
   again (200 → ok, else the 401/429/other notes below). Refresh refused
   (400/401): revokedFlag → `.revoked(note: "login revoked by a later
   `codex login`")`; else `expired` "access token rejected and the refresh
   was refused; log in again". Refresh other →
   `error` "OpenAI's token endpoint answered <code>". 429 → `error` "OpenAI
   is rate limiting usage checks; try again later". Other → `error` "OpenAI's
   usage endpoint answered <code>".

`fetchedAt` = now for every record.

Both probes share one token step with redeem: Claude's `fresh` (the expiry
check of step 1) and each provider's `renewed` (spend the grant, splice the
answer) return `Fresh.ready(doc)` or `.stale(state, note)`.

Limit resets (`redeem(_ i: ProbeInput, …) async -> Redemption`, the doc,
refreshed or not, plus `Result<ResetOutcome, KibaError>`; every token or
endpoint failure is `remote(note)`):

- Token: the doc's access token. Claude: expired as in step 1 → live:
  "access token expired; Claude Code refreshes it on its next run"; saved:
  refresh. A 401 from the reset call on a token not refreshed a moment ago →
  live: that live note (Codex: "access token rejected; run codex once to
  refresh it"); saved: refresh, send again. The live token is never refreshed.
- Claude: POST `https://api.anthropic.com/api/organizations/<org>/reset_rate_limits`,
  `<org>` = `Identity.org` (`oauthAccount.organizationUuid`; empty →
  `badJSON`), bearer, `anthropic-beta`, UA `claude-cli/<version> (external,
  cli)`. Body
  `{"program":"cedar_ember","grant_id":<grant>,"request_id":<UUID>}` or
  `{"program":"juniper_tide"}`; another program → `noResets`. 200
  `{"result":…}`: `reset` | `already_used` | `not_limited` | `cooldown` |
  `ineligible` | `unavailable` → the matching `ResetOutcome`.
- Codex: POST `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume`,
  bearer, `ChatGPT-Account-Id` when present, UA `codex-cli`, body
  `{"redeem_request_id":<UUID>}`. 200 `{"code":…}`: `reset` → reset,
  `nothing_to_reset` → notLimited, `no_credit` → noCredit, `already_redeemed`
  → alreadyUsed.
- Notes, as the probe's: unreachable "<endpoint> could not be reached"; 200
  not an object "…sent an answer that is not a JSON object"; unknown word
  `<endpoint> sent an unknown result "<x>"`; 401 after a refresh → the
  provider's "login rejected by …; log in again"; 429 "<Anthropic|OpenAI> is
  rate limiting limit resets; try again later"; other "<endpoint> answered
  <code>". The endpoints are "Anthropic's reset endpoint" / "OpenAI's reset
  endpoint".

### Switcher

```swift
public final class Switcher: Sendable {
  public init(paths: Paths, store: Store, http: HTTPClient, clock: Clock)
  public func save(_ p: Provider) throws -> SlotName?          // nil when no live login
  public func use(_ p: Provider, _ n: SlotName) async throws
  public func forget(_ p: Provider, _ n: SlotName) throws
  public func probeAll(_ p: Provider) async -> ProbeReport     // never throws
  public func redeem(_ p: Provider, _ n: SlotName) async throws -> ResetOutcome
}
public struct ProbeReport { public var saveBackError: String?; public var providerError: String?; public var accounts: [Probed] }   // accounts: only outcomes recorded
public struct Probed { public let name: SlotName; public let outcome: ProbeOutcome; public let live: Bool }   // live: probed as the live login
```

Each provider's operations run one at a time, first come first served:
`use`, `probeAll`, `redeem`, `save`, `forget` and `LoginRunner.add` each
hold the provider's turn from start to end (`add`: once its CLI is found),
across every network wait; the import and probe `add` runs are
`importInTurn` and `probeInTurn`, which take no turn of their own. So a
probe that is spending a saved login's refresh token finishes before a
switch can make that login live.
The async operations suspend while they wait; the synchronous ones block
their thread. Other processes are held off only by store transactions, so
every probe outcome and refreshed login is written only while the row still
holds the login bytes it was read with (compared inside the `write`); a row
replaced or forgotten meanwhile is never updated or removed.

- `save`: inside one `store.write`, `isMixed` → `mixed`; the provider's
  `login()` nil → nil; else `liveName` from its identity and `put` of its
  bytes. One read chooses the slot for the very bytes saved, so a login the
  CLI rewrites meanwhile cannot land under another account's name; the
  write lock holds off another process's install, which writes both live
  files in one transaction, so the check and the read never see half of
  it. The save-backs of `use` and `probeAll` run the same way.
- `use`: save-back (skip when mixed; save when a live identity exists),
  then `noteInstalled` the saved-back name, whose login the live files
  hold, so a crash between the install's two live writes leaves a pending
  install whose installed name owns the live tokens (`probeAll` treats it
  as live); then install `n`; then probe `n` as live and `write` its
  usage; then, when the save-back named an account other than `n`, probe
  that one as saved and `write` it like `probeAll` does. Its usage came
  from a live probe, which never refreshes, so an expired token would
  otherwise leave it dead ("log in again") once inactive.
- `probeAll`: save-back (an error becomes `saveBackError`), `list`. Live
  Claude credentials without a config stop it here: `orphanLive` is both
  `saveBackError` and `providerError`, no account is probed. Then
  for every saved account: probe (`live` = name == live name, or, while
  the Claude files are mixed, the installed name); `write`, when the row
  still holds the probed login: `setUsage`, `setLogin` when the doc
  changed, or on `.revoked` for a non-live account `remove`. The live
  account is never refreshed and never removed. `accounts` holds only
  outcomes recorded: one whose row was replaced or forgotten meanwhile is
  not written and not in it, nor is one whose write failed, which
  `providerError` names ("<name>: usage not recorded: <reason>"). A pending
  Claude install stops it before any probe: `unrepaired` is the
  `providerError` (the `saveBackError` is `mixed`).
- `redeem`: `noAccount` without the row; `noResets` unless its
  `usage.resets.count > 0`. `live` = `n` in `liveNames(p, mixed:
  isMixed(p))`, as `probeAll` decides it; `unrepaired` while a Claude
  install is pending. The provider's `redeem`; a changed
  doc is stored with `setLogin`, while the row still holds the login it
  refreshed, before the result is read (a refresh spends the old grant); a
  failure throws; after a 200, `probe(p, n, live:)` so the
  row's usage and offer show the result, then the outcome.
- `importInTurn` (internal; only `add` calls it, in its turn): reads the
  login once from the throwaway root (Claude: config at
  `root/.claude/.claude.json` and `claudeCreds` bytes; Codex:
  `root/.codex/auth.json`), `liveName` and `put`, all inside one
  `store.write`. `noLive` when nothing is there.

### Status

```swift
public struct LiveLogin: Equatable, Sendable { public var email: String; public var plan: String }
public struct Account: Equatable, Sendable, Identifiable { public var name: SlotName; public var plan: String; public var active: Bool; public var usage: UsageRecord?; public var id: String { name.raw } }
public struct ProviderStatus: Equatable, Sendable { public var provider: Provider; public var live: LiveLogin?; public var accounts: [Account]; public var error: String? }
public struct Snapshot: Equatable, Sendable { public var providers: [ProviderStatus] }

public struct StatusReader { public init(paths: Paths, store: Store); public func read() -> Snapshot }
```

Per provider, in this order so a broken live file still lists the saved
accounts: `store.list` (plan, usage); live identity; `active` = name ==
`liveName(live)`. Any throw becomes `error` (`reason`) with `live = nil`,
accounts kept. Never opens a write transaction.

### Rows (port of Panel.qml, pure)

```swift
public enum RowState: Sendable { case ok, tight, blocked, dead, unsubscribed, unknown }
public enum Rows {
  static func isLong(_ label: String) -> Bool        // contains week|7-day|month|30-day (case-insensitive)
  static func session(_ u: UsageRecord?) -> Limit?   // first !isLong with percent ≥ 0
  static func weekly(_ u: UsageRecord?) -> Limit?    // first isLong with percent ≥ 0
  static func blocking(_ u: UsageRecord?) -> Limit?  // among percent ≥ 100: latest parseable reset, else the first
  static func headline(_ u: UsageRecord?) -> Limit?  // session ?? weekly
  static func dead(_ u: UsageRecord?, active: Bool) -> Bool   // revoked, or expired && !active
  static func state(_ u: UsageRecord?, active: Bool) -> RowState
  static func rank(_ s: RowState) -> Int             // ok 0, tight 1, blocked/dead/unsubscribed 2, unknown 3
  static func sorted(_ a: [Account]) -> [Account]    // rank; rank 2 by blocking reset (unparseable last); else input order
  static func figures(_ u: UsageRecord?) -> [Figure] // session, weekly, then other percent ≥ 0 in order; each (label, left = 100 - percent)
  static func figuresText(_ u: UsageRecord?) -> String   // "limit" when blocked, else "72% · 40% · 9%"
  static func plan(_ a: Account) -> String           // the saved plan; "no plan" while unsubscribed
  static func planText(_ a: Account, now: Date) -> String // "(pro)", "(pro, 5d)", "(pro, log in again)", "(no plan)", ""
  static func tooltip(_ p: Provider, _ a: Account, now: Date) -> [String]
  static func resets(_ u: UsageRecord?) -> Int       // the offer's count; 0 without one
  static func resetsText(_ n: Int) -> String         // "1 limit reset" | "2 limit resets"
  static func resetShort(_ iso: String, now: Date) -> String  // "20m" | "5h" (<36h) | "2d"; "" unparseable
  static func resetLong(_ iso: String, now: Date) -> String   // "20 min" | "5 h 12 min" (<48h) | "3 days"
  static func age(_ epoch: Int, now: Date) -> String          // "just now" | "12 min ago"
  static func parseISO(_ s: String) -> Date?                  // ±offset, Z, any fractional digits
}
public struct Figure: Equatable { public var label: String; public var left: Int }
```

State: dead → `.dead`; record `unsubscribed` → `.unsubscribed`; no usage or
no limits → `.unknown`; any percent ≥ 100
→ `.blocked`; headline left < 50 → `.tight`; any long window other than the
weekly with left < 50 → `.tight`; else `.ok`. Tooltip lines: `email · plan ·
current` (`plan`: "no plan" while unsubscribed, since the saved plan is the
token document's stale claim); "Usage not probed yet" | note or "No limits reported" | one line
per limit `"<label>: 72% left · resets in 5 h 12 min"` (or "limit reached");
"2 limit resets available" while `resets` > 0; "Probed 12 min ago"; then "Click to log in to this account again" (dead) or
"Click to switch <title> to this account" (not active).

### Add account (LoginRunner)

```swift
public protocol TerminalLauncher: Sendable { func open(_ script: URL) throws }
public protocol Keychain: Sendable {
  func item(_ service: String) -> SecretStore            // the generic-password item of a service
}
public struct AddResult: Equatable { public var saved: SlotName; public var expected: String?; public var differs: Bool }
public actor LoginRunner {
  public init(paths: Paths, switcher: Switcher, terminal: TerminalLauncher, keychain: Keychain, searchPath: String) throws
  public func add(_ p: Provider, expected email: String?) async throws -> AddResult
}
```

Production: `TerminalApp` runs `/usr/bin/open -a Terminal <script>`;
`KeychainTool` hands back `KeychainItem`s under the user's account.
The item of `add`'s Claude login is named, never searched for. Claude Code 2.1.282
derives its service from the config dir:
`dir = ($CLAUDE_CONFIG_DIR ?? ~/.claude)` in NFC; the service is
`Claude Code-credentials`, plus `-` and the first 8 lowercase hex digits of
SHA-256 of `dir`'s UTF-8 bytes when `CLAUDE_CONFIG_DIR` is set and non-empty;
the account is `$USER`, else the login name. `Paths` holds that
derivation once: the login script exports
`claudeConfigDir(root: loginRoot(.claude)).path`, so `paths.loginService`
names that item, and `paths.keychainService` the live one, the item of the
app's own `CLAUDE_CONFIG_DIR` (tests' base service stands in for
`Claude Code-credentials`). Items of other config dirs, which refresh on
their own, are never read.
`searchPath` is the PATH searched for the CLIs; `CoreBackend` takes it from
the user's login shell (`$SHELL -lc`, PATH printed between markers so
profile output cannot pollute it), because an app started from Finder or a
login item inherits only the system default PATH, which lacks the CLIs.

`init` undoes an add the app did not live to finish before anything reads
the live login: when `store.adding(.claude)` holds a record, it stops that
login if it still runs, puts the live item back as in 5 with `before` taken
as absent (no snapshot of the login's item outlives the app), and removes
`paths.loginRoot(.claude)`. A Claude `add` does the same first, in its
turn, so the record a failed stop (4) kept is put back before its own
snapshot (3) replaces it.

`add` holds a per-provider lease from its first line to its return, across
every await. Every login of a provider uses the same root, so a second `add`
for a provider whose login is in flight throws `loginRunning` rather than
queueing. The lease is per `LoginRunner`, and that is enough: the app makes
one, and LaunchServices activates a running Kiba rather than launching a
second, so no other process ever shares a root. Once its CLI is found (1),
`add` also holds the provider's turn (`switcher.ops(p)`, see Switcher), so no
`use` installs a login between the snapshot in 3 (Codex: the login) and the
restore in 5, nor between the import in 7 and its probe, which would then
refresh a login made live meanwhile. The app is busy for the whole add, so
the held turn shows nowhere.

1. `claude`/`codex` must be on `searchPath` (`noCLI`); the script runs the
   one found. Root = `paths.loginRoot(p)`:
   remove, create 0700, create `root/.claude` or `root/.codex`.
2. Write `root/nonce`, a UUID fresh for this run, and `root/login.command`
   (0700):
   ```sh
   #!/bin/sh
   [ "$(cat '<root>/nonce' 2>/dev/null)" = '<nonce>' ] || exit 1
   printf '%s' "$$" > "<root>/pid.tmp" && ln "<root>/pid.tmp" "<root>/pid" || exit 1
   export CLAUDE_CONFIG_DIR="<root>/.claude"      # or CODEX_HOME="<root>/.codex"
   report() { printf '%s' "$1" > "<root>/exit.tmp" && mv "<root>/exit.tmp" "<root>/exit"; }
   trap 'report 129; exit 129' HUP                # INT 130 and TERM 143 alike
   printf 'Sign in to %s at %s in your browser, then press Enter to continue: ' '<email or "the account to add">' '<site>'
   read -r _
   claude auth login --email '<email>'            # or: codex login   (no --email without one)
   rc=$?
   trap - HUP INT TERM
   report "$rc"
   if [ "$rc" -ne 0 ]; then printf '\nPress Enter to close\n'; read -r _; fi
   exit "$rc"
   ```
   Shell-quote every interpolated value. The nonce check keeps a script an
   earlier add wrote, which Terminal may start only once root was made
   again, from running in the new root. The hard link publishes the pid
   whole and fails when the name exists, so a stop can claim it first.
3. Claude only: snapshot `before`, the bytes of the login's item
   (`keychain.item(paths.loginService)`, nil when absent), and `old`, the
   live item's bytes (`KeychainItem.read()`). Commit
   `tx.noteAdding(.claude, LiveItem(bytes: old))` before the launch.
4. `terminal.open(script)`, then wait for `root/exit` (directory watch via
   `DispatchSource`, plus a 1 s poll as belt and braces). A wait that ends
   without a status (the task was cancelled, the file is unreadable) or a
   failed open stops the login; its error is thrown after 5. A stop that
   fails throws at once: the login may still run, so root and the `adding`
   record stay for the next start or Claude `add`.
5. Claude only, whatever 4 ended in: put the live item back when the login
   wrote it, which it did only when it filed its credentials nowhere in its
   own home (6a and 6b find nothing). Then live bytes that differ from
   `old` are kept as `written`, and `old` is written back (the item removed
   when `old` is nil). Otherwise a changed live item is Claude Code's own
   refresh and stays: with `CLAUDE_CONFIG_DIR` set, 2.1.282 files a login
   under `paths.loginService` and never writes the live item, and stale
   tokens written over a refresh could end the live login. Then
   `tx.clearAdding`. A restore that fails leaves the record for the next
   start. Then a non-zero status → `loginFailed`.
6. Locate the new credentials (Claude), reading only, first hit wins:
   a. `root/.claude/.credentials.json` exists → its bytes.
   b. the login's item holds bytes that differ from `before` → those
      bytes; the item is the source. Content, not existence: the login
      home's fixed path always names the same item, and an earlier add
      killed before its removal leaves that item behind.
   c. `written` → the login wrote the live item and nothing else (5).
   d. → `loginProducedNothing`.
7. `switcher.importInTurn(p, root, claudeCreds)`. Only once it has committed
   are the source item (6b) deleted and root removed: a failed import leaves
   both in place and throws its error. Then probe the new account
   (`probeInTurn`, `live: false`) and `write` its usage. `differs` =
   expected email given and `saved.email != expected`. Any failure before 7
   removes root, except a stop that fails (4).

Stopping a login: claim `root/pid` by an exclusive create. When that
succeeds the script has not filed its pid and, its link failing, exits
without running the login; a missing root has nothing running from it.
Otherwise the file holds the script's pid. When that process still runs
the script (its arguments name `root/login.command`; a pid since reused
names something else), SIGTERM goes to its process group, which ends the
CLI and makes the script report as for a closed window, and SIGKILL follows
after 5 s.

The live login is never read by the provider's login command and never
revoked: the throwaway home guarantees that on Codex; on Claude the restore
in 5 covers a login that writes the live item on every outcome, and the
`adding` record carries it across a crash to the next start. Credentials a
login wrote only over the live item (6c) are lost when the import fails: the
live login comes first. Keeping them is not worth more machinery: only an
old CLI writes there, and what such a failure loses is the new login, which
another add redoes, never the live one.

## KibaApp

### AppModel (`@MainActor @Observable`)

The model talks to the core through one seam:

```swift
public protocol Backend: Sendable {
  func status() -> Snapshot
  func use(_ p: Provider, _ n: SlotName) async throws
  func save(_ p: Provider) throws -> SlotName?
  func forget(_ p: Provider, _ n: SlotName) throws
  func probeAll(_ p: Provider) async -> ProbeReport
  func add(_ p: Provider, expected: String?) async throws -> AddResult
  func redeem(_ p: Provider, _ n: SlotName) async throws -> ResetOutcome  // spend one limit reset, re-probe
}
public enum ResetOutcome: String, Equatable, Sendable {
  case reset, notLimited, alreadyUsed, noCredit, cooldown, ineligible, unavailable
}
```

`Backend.swift` in KibaCore holds the protocol plus `ProbeOutcome`,
`ResetOutcome`, `ProbeReport` and `AddResult`; `CoreBackend` (Switcher + StatusReader + LoginRunner) is the
only production conformer. Tests drive `AppModel` on a scratch HOME through
the same `CoreBackend`, wrapped to hold its status reads at a gate when a
test needs a read in flight.

State: `snapshot: Snapshot`, `availability: .ready | .failed(String)`,
`refreshing`, `busy`, `message`, `note`, `error`, `lastProbe: ProbeRun?`
(epoch the latest probe of every account started, `clean`: nothing failed
or waited and every provider was probed, and the usage it recorded per
account; `complete(snapshot)`: clean, and every row the snapshot shows
holds the usage the run recorded, so a row it missed or one added since
leaves it partial after the read that shows it), `panelOpen`, `autoProbed`, `now`
(ticks every 30 s while open), `cursor: ActionKey?`, `confirming: Choice?`
(kind `forget` | `reset`, provider, name), `refreshIntervalSec` (UserDefaults,
default 120, min 15).

- `refresh(force:)`: skip when the last good read was < 5 s ago unless
  forced; coalesce when one is running; `StatusReader.read()` on a
  background task; success → snapshot, availability ready, and the status
  error cleared (action and probe errors stay until Dismiss or the next
  action); failure → availability failed, status error = reason.
- Opening the panel: reset cursor, `autoProbed = false`, `refresh()`, then
  `maybeAutoProbe()` (once per open when any provider has saved accounts and
  nothing is busy); start the interval refresh and the clock tick. Closing
  stops both; it clears no notice.
- Notices. Each action returns an `Outcome` (text, `held`, errors). A plain
  confirmation shows in `message` and fades after 4 s. A held result goes
  to `note` and every error to the action error; both stay until Dismiss
  (`dismiss()`) or the next action the user starts supersedes them. An
  error reported while an action runs (`report`) joins that action's
  errors when it finishes. The probe that opening the panel starts
  supersedes nothing: its held lines, errors and gauge faults join what is
  shown, skipping lines already there. Held: "Added <x>, not <y>" and a
  probe that missed accounts; plain: every other result.
  `announce` (set by the status item to post
  `NSAccessibility` `.announcementRequested`, high priority) speaks each
  action's result and errors as it finishes, and each reported error; the
  opening probe speaks only the lines it adds, so a held note is spoken
  once and an open does not repeat it. The status error is separate: set
  by a failed read, cleared by the next good one.
- Actions (`busy` guards all):
  `use(p, name)` — a dead row starts `add(p, name.email)` instead;
  `save(p)`; `add(p, email?)` closes the panel first; `probeUsage()`
  probes every provider and counts accounts per outcome: refreshed (the
  provider answered: record `ok`, `unknown` or `unsubscribed`), waiting (record `expired`
  on a row probed as live: its CLI refreshes the token, kiba never does),
  failed (record `expired` on a saved row, `error` or `revoked`: no fresh
  usage), removed (`.revoked`) and not probed (a row shown with no
  outcome: its provider could not be probed, or its login changed before
  its usage was recorded). Each row shown when the probe ends and each
  account a report names counts once, so a provider that fails whole
  still counts its rows. Wording: nothing saved "No saved
  accounts to refresh"; all refreshed "Usage refreshed for 2 accounts";
  some "Usage refreshed for 1 of 3 accounts: 1 failed, 1 removed",
  "…: 1 live login waiting for its CLI" or "Usage refreshed for 2 of 4
  accounts: 2 not probed"; none "Usage not refreshed: 2
  failed"; a failed or removed account adds "<Provider>: <name>: <note>" or
  "<Provider>: removed <name>, <note>", and save-back and provider errors
  become errors, each line once. A result that missed any account is
  held, every other is plain; `lastProbe` records a run that reached any
account, and one that reached none leaves the last standing, so the meta
line and the Refresh usage row keep the latest actual probe's age.
`forget(p, name)`;
  `redeem(p, name)` — "Resetting
  limit for <name>…", `Backend.redeem`, then one sentence per outcome:
  reset "Limit reset for <name>", notLimited "<name> is not at a limit;
  nothing was spent", alreadyUsed "That reset was already used", noCredit
  "No limit resets left for <name>", cooldown "Limit resets are cooling
  down for <name>; try again later", ineligible "<name> cannot reset its
  limit", unavailable "Limit resets are unavailable for <name> right now".
  Forget (the row's context menu, or ⌫/⌦ on the row: `forgetCursor()` asks
  for the cursor's account row and does nothing elsewhere) and Reset (the
  row's badge) ask first through one mechanism: `ask(kind, p, name)` sets
  `confirming`, the row turns into its
  confirmation and the cursor goes to Keep; the go button (`confirm`) runs
  the kind's action; Keep or ⎋ ends it and returns the cursor to the
  control that asked, the row or its badge. A confirmation ends with the
  read that shows its row gone or, for a reset, its offer spent. Each
  action ends with a forced status read and stays `busy` until that read,
  and any queued behind it, has applied its snapshot or failed: controls
  re-enable only over rows that show the action's result.
- `actions: [ActionKey]`, every control a click can reach, in panel
  order: `dismiss` while a result or a shown action error is held; `retry`
  while the status read has failed and no read runs; per
  provider `add`, every account row (`use`), each followed by its badge
  (`redeem`) while `Rows.resets` > 0, then `save` when the provider has a
  live login, no error and no active row; `usage` at the end. A confirming
  row contributes its `confirm` and `keep` buttons in place of `use` and
  `redeem`. `trigger(_:)` runs every key; the cursor tracks its key across
  refreshes and stays at the same position when its key is gone.

### Status item and popover

`NSStatusItem` with a custom 18×18 image drawn by `GaugeIcon`. Left click
toggles an `NSPopover` (`.transient`, `NSVisualEffectView` `.popover`
material) hosting `PanelView`; right click, or Control-click with the mouse,
shows the app menu: Refresh usage, Start at login, Quit. Only a mouse event
counts as a right or Control-click: a press from the keyboard or VoiceOver
(whose keys hold Control) toggles the panel. Keyboard and VoiceOver reach
the menu two ways: the button's accessibility custom action "Show Menu"
(VoiceOver's actions menu, VO-⌘-Space), which returns before the menu
tracks; and, while the panel is open, the system's context-menu key (⌃⏎
unless the user changed it; macOS 15 and later), which `KeyCatcher` takes
as first responder and hands to the status item through `AppModel.showMenu`:
the panel closes and the menu opens under the icon, as on a right click.
`LSUIElement` true. The icon
tooltip lists `<title>: <live email or none>` per provider, or "AI accounts"
while unavailable. The button's accessibility value (`AppModel.iconValue`)
names each provider's cell ("Codex: 80% left", "none left", "usage
unknown", "error"), then each provider error and the error showing.

Start at login follows `SMAppService.mainApp.status`: `.enabled` shows on
and a click unregisters; `.notRegistered` shows off and a click registers,
then opens Login Items settings if macOS asks for approval;
`.requiresApproval` shows mixed, titled "Start at login (needs approval in
Login Items)", and a click opens Login Items settings; `.notFound` shows off
and a click registers like `.notRegistered`, since macOS has no record of an
app before its first registration (Apple DTS). Only a register or unregister
that throws, or a status newer than this build, is reported, as
`KibaError.loginItem`.

### Visual design

Subject: allowance that drains and refills on a schedule. The panel's one job
is to answer "which account has room, and how much". Everything is native
material and system type except one signature and one risk.

Tokens (`Theme.swift`). The custom colors resolve for four appearances:
light (`aqua`), dark (`darkAqua`), and each under Increase Contrast
(`accessibilityHighContrastAqua`, `accessibilityHighContrastDarkAqua`).
Light values hold 3:1 against the track on the popover material and the
red holds 4.5:1 as text on both; the Increase Contrast values hold 7:1
against the window background and 3:1 against the raised track.

| token   | light     | dark      | light, contrast | dark, contrast | use |
|---------|-----------|-----------|-----------------|----------------|-----|
| `room`  | `#1F7F52` | `#4FC08A` | `#0F5132`       | `#6FD9A4`      | segments half or more full; the dot of a usable account |
| `low`   | `#9E6A0E` | `#E2A93B` | `#6B4700`       | `#F2C263`      | segments under half |
| `out`   | `#B52F2F` | `#F07070` | `#8F1F1F`       | `#FFAAAA`      | "limit", "log in again", "no plan", errors, the red dot, Forget, the urgent icon |
| `track` | quaternary label color | quaternary label color | tertiary label color | tertiary label color | empty reservoir |

The rest are system colors, which follow every appearance themselves:

| token      | color                                 | use |
|------------|---------------------------------------|-----|
| `idle`     | secondary label color                 | meta and plan text, the unknown dot, idle controls |
| `ink`      | label color                           | names, figures, the row fill |
| accent     | `Color.accentColor`                   | the active account's name; the badge |
| `onAccent` | alternate selected control text color | the badge's count |
| `focus`    | keyboard focus indicator color        | the ring on the badge under the cursor |

Type: system text styles only, the HIG's recommendation for Mac text, so
every size and weight is the style's macOS default rather than a fixed point
size (macOS has no Dynamic Type; the panel claims no text scaling): title
`.title3.bold()`; section headers
`.headline` in sentence case ("Claude Code", "Codex"), `ink`; names `.body`
(`.bold()` when active); meta and plan text `.subheadline`, `idle`; figures
`.subheadline.monospacedDigit()` in `ink`; the badge's count
`.caption.bold().monospacedDigit()`. Section headers are accessibility
headings. Text is never colored by usage
state: the bars carry the color, and only "limit", "log in again" and "no
plan" (plan text and figures of a blocked, dead or unsubscribed row) are
`out`. Rows and actions are
`Button`s (`.plain` style, keyboard and VoiceOver for free); the add action
is `Button("Add Claude Code account", systemImage: "plus")` (the
provider's title), `.iconOnly`, `.accessoryBar` style. Reduce Transparency swaps the popover material for
the window background; Increase Contrast resolves every custom token to its
contrast column, the empty track included; Reduce Motion stops the fill
animation.

Layout (width 340, vertical padding 10, row inset 10). The panel is as tall
as its content, capped at the menu bar screen's visible height less 24 pt
(measured before each show); taller content scrolls, with the system's
scroll indicators (`.automatic`: overlay scrollers show while it scrolls,
or always under the "Show scroll bars: Always" setting). Each provider's
header line carries the add action at its
right, a standard plus button, `accent` under the keyboard cursor, tooltip
its label, "Add Codex account"; there is no add row. Cursor order: Dismiss,
Retry, then per section add, accounts (each followed by its badge), save,
then Refresh usage (`AppModel.actions`).

```
┌──────────────────────────────────────────────┐
│ Room to work                 Probed 2 min ago│  title · meta
│ ──────────────────────────────────────────── │
│ Claude Code                                + │  section header · add
│ ● joel@x.com (max)            72% · 40% · 9% │  dot · name · plan · figures
│ ████████░░  ████░░░░░░  █░░░░░░░░░           │  reservoir: usable limit left
│ ● other@x.com (pro, 5d)            limit (2) │  red dot: limited; 2 resets
│ ░░░░░░░░░░  ░░░░░░░░░░                       │  drained: nothing usable
│ Save the current login                       │  action row
│ Codex                                      + │
│ ● me@y.com (plus)                  88% · 61% │
│ █████████░  ██████░░░░                       │
│ ──────────────────────────────────────────── │
│ Refresh usage                    2 min ago   │
└──────────────────────────────────────────────┘
```

Signature — the **reservoir**: under every account row a 4 pt bar split
into one segment per window (session, week, each model window, in figure
order), 3 pt gaps, radius 2, track `track`, fill from the left = left/100,
each segment in its own color: `room` with half or more left, `low` under
half (`Rows.isLow`); a remainder too thin to see still draws a sliver as
wide as the bar is tall. The track is always grey. The bar shows the
**usable** limit left: when the account cannot take work (`Rows.usable`
false: a window at its limit, dead, or without a plan) it is drained, every segment an
empty track, because a limited account has no usable limit left whatever
its other windows hold. A row with no figures yet (unknown usage) shows two
empty tracks, session and week, so the bar is never missing. The verdict is
the **status dot** before the name (8 pt): `room` green when the account
can take work (ok or tight), `out` red when it is limited, dead or without
a plan, `idle`
grey while unknown;
under Differentiate Without Color it is a check, cross, or question mark
symbol. The
verdict also lives in the sort order and the plan text. The reset countdown
lives in the plan text `(pro, 5d)`. The menu bar icon is the same
idea at 18 px: one thin vertical cell per provider (`Gauge.Cell`), each
state its own shape: filled from the bottom to the active account's
headline remaining (`level`); outline only when unknown or no account is
current (`unknown`); struck through corner to corner when nothing usable is
left, at a limit or logged out (`spent`); an exclamation mark, bar over
dot, on an error (`fault`: that provider's status error, or every cell
while an error is showing). Drawn `out` while an error is showing, at 50 %
opacity when unavailable, otherwise the menu bar's label color.

The **limit-reset badge** ends the name line, after the figures, of every
row whose `Rows.resets` > 0, blocked and dead rows included (that is when
it matters): the macOS badge idiom, the count in `onAccent` on an `accent`
capsule 18 pt tall, a circle for one digit. It is a `Button` of its own laid
over the row, not inside the row's button, so clicks, the cursor and
VoiceOver reach it apart from the row; the name line keeps its place without
growing. Tooltip "2 limit resets available. Click to use one." (singular
for 1); VoiceOver reads "2 limit resets", hint "Uses one reset". Under the
cursor it wears a 2 pt `focus` ring 1.5 pt outside it, inside its hit area,
and the row does not light; the pointer leaving it for the row hands the
cursor back to the row. The digits carry it under Differentiate Without
Color. A click asks first, like Forget.

Rows: no boxes; a row highlights with `ink` at 10 % under the pointer or the
keyboard cursor, 5 % when active. One line: dot, name, plan, figures, badge.
Plan and figures are short bounded strings (the login's one-word plan, a
reset countdown or "log in again", a percentage per window or "limit"), so
they always fit at their full width and one line always holds the row; the
name alone gives way,
laid out first (`layoutPriority`) with every point they leave and shortened
in the middle ("nfnht45…leid.com") so both ends still name the account, as
the original kiba did. The whole name is in the tooltip and the VoiceOver
label. Blocked, dead and unsubscribed names are `idle`; blocked figures
read `limit`; dead plan text carries "log in again"; an unsubscribed row's
plan text is "no plan", never the saved plan. VoiceOver reads a row as
one button: label "<Provider>: <name>" plus ", current account"; value the
plan (none while unsubscribed), the verdict ("has room"; "limit reached, resets in 5 h 12 min";
"login required, log in again"; "usage not probed yet", the record's note,
or "no limits reported"), each window "<label>: 72% left", and "probed 12
min ago"; hint "Switches <Provider> to this account" (none on the active
row) or "Logs in to this account again", then "Delete asks to forget it",
joined with ". ". The dot and reservoir are hidden from it: the value says
what they show. Motion: reservoir fills animate `easeOut(0.35)` on data change,
disabled under Reduce Motion. Hover shows the tooltip lines via `.help`.
Keyboard: ↑/↓ and ⇥/⇧⇥ move the cursor (scrolling it into view), ⏎ and
Space activate the cursor's control, ⌫ or ⌦ on an account row asks to
forget it (the same confirmation as its context menu; the row's VoiceOver
hint names it), the system's context-menu key opens the app menu (see
Status item), ⎋ backs out of a confirmation, else closes; hover moves the
cursor without scrolling. On a confirming row
the cursor stops on its go button (Forget or Reset) and on Keep, each lit
with the row fill behind its label. The control under the cursor is the accessibility focus, and a
control VoiceOver focuses takes the cursor, so both always name one
control. `KeyCatcher` holds first responder while the panel is key; that
is safe because the panel has no text field or other control that reads
keys, and the cursor reaches every control a click can, so it replaces the
key-view loop rather than hiding a control from it.

Copy: "Room to work" (title), meta = "Working…" | "Refreshing…" | "All
usage probed 2 min ago" (the latest probe, complete) | "Some usage probed 2
min ago" (it missed accounts) | "Oldest usage from 40 min ago" (no probe
yet: the oldest record shown) | "Saved logins" (no records) |
"Unavailable"; the Refresh usage row's detail is the latest probe's age, and
each row's tooltip and VoiceOver value carry its own record's age. "Not
logged in" under a provider without a live login, or the provider's error,
up to 3 lines; "Retry" row when status failed; error, held note and
message below the title (error in `out`, note in `ink`, message
in `idle`, each shown whole: the panel scrolls), with a Dismiss button (an
`xmark`, "Dismiss notice") at their right while a note or action error is
held. Action names stay the same through the flow: "Save the current
login" → "Saved joel@x.com"; "Switching Claude Code to other@x.com…" →
"Claude Code: now other@x.com"; "Resetting limit for other@x.com…" →
"Limit reset for other@x.com". Confirmations, the question up to two lines
and eliding in the middle: "Forget <email>?" with **Forget** (destructive,
`out`) and **Keep**; "Use a limit reset on <email>? (2 left)" with
**Reset** (`accent`, not destructive) and **Keep**.

## Build, bundle, test

- `swift build` / `swift test` from the package root. Tests are
  integration tests: each one sets `HOME`, `CLAUDE_CONFIG_DIR` and
  `CODEX_HOME` to a scratch directory, seeds live files and saved rows, drives
  `Switcher`, `StatusReader`, `LoginRunner` (with fake `claude`/`codex`
  executables on a scratch PATH) or `AppModel`, and asserts the resulting
  files, Keychain item (`kiba-mac-test-<uuid>`, removed in `defer`), HTTP
  requests (`StubHTTP`), and snapshot. No per-type unit suites.
- `build.sh`: `swift build -c release`, assemble `build/Kiba.app`
  (`Contents/MacOS/Kiba`, `Info.plist`: `CFBundleIdentifier
  io.github.joelreymont.kiba`, `LSUIElement` true, `LSMinimumSystemVersion
  14.0`, `NSHighResolutionCapable`; `Resources/AppIcon.icns` rendered by
  `Scripts/icon.swift`), `codesign --force --sign -`, then copy to
  `~/Applications/Kiba.app` (replace via rename).
- `test.sh`: `swift test` with the scratch env exported (defence in depth).

## Store layout

```
~/Library/Application Support/Kiba/     0700
  kiba.db                               0600, plus SQLite's -wal and -shm
  probe/                                scratch: login-claude/, login-codex/
```

The live login files stay where the provider CLIs read them (`~/.claude.json`,
the Claude Keychain item or `.credentials.json`, `~/.codex/auth.json`) and
are written by `PrivateFS` temp + rename.

## Decisions and their reasons

- `/usr/bin/security` over the Security framework: Claude Code creates the
  item with `security`, so `security` is on its ACL and, while the
  keychain is unlocked, does not prompt; a
  differently signed app would prompt on every rebuild and after every
  fresh login. The secret goes in on stdin under `setsid` whenever it fits
  the tool's line buffer, and in argv only beyond that, matching Claude
  Code's own exposure rather than adding a Keychain prompt to avoid it.
- Login through the provider's own command in Terminal: the OAuth flows are
  undocumented and change; the throwaway home keeps the live login out of
  reach, and the three-way credential detection covers every place a Claude
  login under `CLAUDE_CONFIG_DIR` may write.
- Saved accounts in one SQLite file under Application Support, local to
  this Mac and never shared. A row holds what a slot directory held, a
  transaction replaces the lock directory and every temp + rename in the
  store, a `pending` row the install marker, and a status read is two
  queries. Saved
  tokens stay in the 0600 database rather than Keychain items: no
  subprocess per read, and tests check the bytes directly. Nothing moves in
  from an old kiba folder: accounts are added through the provider login.
- No CLI, no Habu, no Forth: the app owns the logic; tests replace the
  Forth suite.
