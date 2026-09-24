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
| paths             | `Paths(env:)`        | process env                        | scratch env               |
| secret bytes      | `SecretStore`        | `KeychainItem`, `FileSecret`       | `MemorySecret`, `FileSecret` |
| HTTP              | `HTTPClient`         | `URLSessionClient`                 | `StubHTTP`                |
| subprocess        | `Subprocess.run`     | posix_spawn                        | real, on throwaway inputs |
| clock             | `Clock` (`() -> Date`) | `Date.init`                      | frozen                    |
| terminal          | `TerminalLauncher`   | `open -a Terminal <file.command>`  | fake that runs the script |
| keychain listing  | `KeychainLister`     | `security dump-keychain` names     | fake                      |

## KibaCore

### Provider

```swift
public enum Provider: String, CaseIterable, Sendable, Codable {
  case claude, codex
  public var title: String        // "Claude Code" | "Codex"
  public var loginFile: String    // slot token document: "credentials.json" | "auth.json"
  public var identityFile: String // slot identity document: "oauth-account.json" | "auth.json"
  public var homeVar: String      // "CLAUDE_CONFIG_DIR" | "CODEX_HOME"
  public var site: String         // "claude.ai" | "chatgpt.com"
}
```

### Errors

```swift
public enum KibaError: Error, Equatable {
  case noLive(Provider)              // nothing to save
  case noAccount(Provider, String)   // no such saved account
  case badName(String)               // unsafe slot name
  case locked(URL)                   // another kiba holds the store lock
  case badJSON(String)               // a login file lacks an expected field / is not JSON
  case loginFailed(Int32)            // provider login exited non-zero
  case loginProducedNothing(Provider)// login exited 0 but no credentials were found
  case noCLI(String)                 // claude/codex not on PATH
  case interrupted(Provider)         // .installing marker present
  case mismatch(Provider, String)    // slot document names another account than its folder
  case mixed                         // live Claude config and tokens name different accounts
  case capacity(String)              // >9 logins under one email, doc over 4 MiB
  case unsafePath(URL)               // symlink chain longer than 8 hops or ends in a link
  case io(String)                    // any file error, with the path
  case tool(String, Int32, String)   // subprocess name, exit status, stderr
}
extension KibaError { public var reason: String }   // one-line, user-facing, no code
```

Every failure path throws; nothing logs and continues. Per-provider and
per-account isolation happens only in `StatusReader` and `Prober`, where the
error becomes that provider's `error` string or that account's usage `note`.

### Paths

```swift
public struct Paths: Sendable {
  public init(env: [String: String], username: String)
  // store: $KIBA_STORE, else $HOME/Library/Application Support/kiba
  public let store: URL
  public var lock: URL              // store/lock  (directory)
  public var probe: URL             // store/probe
  public func providerDir(_ p: Provider) -> URL          // store/<provider>
  public func slotDir(_ p: Provider, _ n: SlotName) -> URL
  public func slotFile(_ p: Provider, _ n: SlotName, _ file: String) -> URL
  public func usageFile(_ p: Provider, _ n: SlotName) -> URL   // usage.json
  public func installedFile(_ p: Provider) -> URL        // <providerDir>/.installed
  public func markFile(_ p: Provider) -> URL             // <providerDir>/.installing
  public func loginRoot(_ p: Provider) -> URL            // store/probe/login-<provider>
  // live files; `root` selects a throwaway home for `add`
  public func claudeConfigDir(root: URL?) -> URL   // root/.claude | $CLAUDE_CONFIG_DIR | $HOME/.claude
  public func claudeConfigFile(root: URL?) -> URL  // <dir>/.claude.json when dir is explicit, else $HOME/.claude.json
  public func claudeCredsFile(root: URL?) -> URL   // <dir>/.credentials.json
  public func codexHome(root: URL?) -> URL         // root/.codex | $CODEX_HOME | $HOME/.codex
  public func codexAuthFile(root: URL?) -> URL     // <home>/auth.json
  public let username: String                      // Keychain account attribute
  public let keychainService: String               // "Claude Code-credentials"
}
```

### SlotName

A slot name is an email, or `email #n` (n ≥ 2). Rules from kiba `NAME-OK?`:
1–127 bytes, no byte < 0x20, no 0x7F, no `/`, no leading `.`.

```swift
public struct SlotName: Hashable, Sendable, Comparable, CustomStringConvertible {
  public init?(_ raw: String)               // nil when NAME-OK? fails
  public let raw: String
  public var email: String                  // part before " #"
  public var suffix: Int?                   // n in "email #n", nil for the bare email
  public func belongs(to email: String) -> Bool
  public static func < (a, b) -> Bool       // different emails: bytewise; same email: by suffix (bare = 1)
}
```

### PrivateFS

```swift
public enum PrivateFS {
  public static func writePrivate(_ data: Data, to url: URL) throws
  public static func ensurePrivateDir(_ url: URL) throws     // recursive mkdir 0700; existing dirs untouched
  public static func removeTree(_ url: URL) throws
  public static func writeTarget(_ url: URL) throws -> URL   // follows ≤ 8 symlink hops; throws unsafePath if still a link
  public static func exists(_ url: URL) -> Bool              // regular file
  public static func isDir(_ url: URL) -> Bool
}
```

`writePrivate`: resolve the write target through the symlink chain (a live
file that is a symlink stays a symlink; the file behind it is replaced), open
`<target>.tmp` in the same directory with `O_WRONLY|O_CREAT|O_TRUNC`, mode
0600 (remove a stale temp first; refuse if the temp path is a symlink), write
all bytes, `rename` over the target. Any failure removes the temp file and
rethrows. Never `Data.write(options: .atomic)`: it does not control the mode.

### JSONDoc — byte-exact splicing

Login documents are rewritten by splicing bytes so every other key keeps its
exact bytes (kiba `SPLICE-CONFIG`, `CFG-REPLACE2`). A round-trip through
`JSONSerialization` is only allowed for documents kiba-mac itself owns
(`usage.json`, `.installed`, `.installing`).

```swift
public struct JSONDoc {
  public init(_ data: Data) throws              // must be a JSON object, ≤ 4 MiB
  public func valueSpan(_ key: String) -> Range<Int>?                 // top-level key's value bytes
  public func objectSpan(_ key: String) -> Range<Int>?                // same, only when the value is an object
  public func valueSpan(_ key1: String, _ key2: String) -> Range<Int>? // one level down
  public func closingBrace() -> (index: Int, hasMembers: Bool)
  public func replacing(_ span: Range<Int>, with: Data) -> JSONDoc
  public var data: Data
}
```

Parsing must skip strings with escapes correctly and nest arbitrarily deep.
Values are located, never decoded. Reading fields (`string(key)`,
`string(key1,key2)`, `int(...)`) is done via `JSONSerialization` on the same
bytes; `JSONDoc` only locates spans for writes.

### StoreLock

```swift
public final class StoreLock: Sendable {
  public init(paths: Paths, clock: Clock)
  public func withLock<T>(_ body: () throws -> T) throws -> T
}
```

`mkdir(store/lock, 0700)` is the mutex; on success write `lock/pid` (this
process's pid, `writePrivate`). On `EEXIST`: the lock is stale when its pid
file names a dead process (`kill(pid, 0)` fails with ESRCH) or when there is
no readable pid and the directory is older than 60 s; a stale lock is removed
(pid, pid.tmp, dir) and `mkdir` retried once; otherwise throw `locked`.
Release removes pid then dir. Non-reentrant: `withLock` inside `withLock`
is a programming error (`preconditionFailure`). Status reads never take it;
probes take it only around slot writes and token refreshes.

### Identity

```swift
public struct Identity: Equatable, Sendable { public var email: String; public var plan: String; public var org: String }

public enum ClaudeIdentity {
  static func fromOAuthAccount(_ obj: Data) throws -> Identity        // {emailAddress, organizationUuid}; plan ""
  static func fromLive(config: Data, creds: Data) throws -> Identity   // config.oauthAccount.{emailAddress,organizationUuid}; creds.claudeAiOauth.subscriptionType
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

`badJSON` when the email is missing. Plan and org are "" when absent.

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
its ACL always admits us and the app never triggers a Keychain prompt:

- read: `security find-generic-password -a <account> -s <service> -w`;
  exit 44 (`errSecItemNotFound`) → nil; other non-zero → `tool`.
- write: `security add-generic-password -U -a <account> -s <service> -w`
  with `-w` LAST and no value, spawned with `POSIX_SPAWN_SETSID` so the
  child has no controlling terminal; `readpassphrase` then falls back to
  stdin, and the secret is piped in (secret + "\n", twice: the tool asks to
  retype). The secret never appears in argv.
- remove: `security delete-generic-password -a … -s …`; exit 44 → no-op.

The live Claude credential store is chosen by existence, never by platform:

```swift
public enum ClaudeSecrets {
  public static func live(paths: Paths, root: URL?) -> SecretStore
  // FileSecret(<configDir>/.credentials.json) when that file exists,
  // else KeychainItem(paths.keychainService, paths.username)
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

```swift
public struct Store {
  public init(paths: Paths)
  public func list(_ p: Provider) -> [SlotName]           // dirs under providerDir holding <loginFile>, sorted by SlotName
  public func slotIdentity(_ p: Provider, _ n: SlotName) -> Identity?  // nil when the identity file is missing/unreadable ("damaged")
  public func slotPlan(_ p: Provider, _ n: SlotName) -> String         // "" when unreadable
  public func liveName(_ p: Provider, live: Identity) throws -> SlotName
  public func installed(_ p: Provider) -> SlotName?       // .installed
  public func noteInstalled(_ p: Provider, _ n: SlotName) throws
  public func installing(_ p: Provider) -> Bool           // .installing exists
  public func markInstall(_ p: Provider, _ n: SlotName) throws
  public func clearMark(_ p: Provider) throws
  public func removeSlot(_ p: Provider, _ n: SlotName) throws
}
```

`liveName` (kiba `LIVE-NAME`): candidates `email`, `email #2` … `email #9`.
For each: no slot dir → first free candidate remembered; slot exists and its
identity's org equals the live org (both empty counts as equal; one empty
does not) → return it; slot exists but damaged → counts as free. Return the
first free; none → `capacity`.

### Claude live login

```swift
public struct ClaudeLive {
  public init(paths: Paths, store: Store, secrets: SecretStore)   // secrets = ClaudeSecrets.live(...)
  public func identity() throws -> Identity?     // nil when config or creds missing
  public func save(to n: SlotName) throws        // slot/credentials.json = creds bytes; slot/oauth-account.json = exact oauthAccount object bytes from config
  public func install(_ n: SlotName) throws
  public func isMixed() throws -> Bool
}
```

`install` (kiba `CLAUDE-INSTALL`): both slot files must exist else
`noAccount`; the slot's oauth-account email must belong to `n` else
`mismatch`; creds must be an object with a `claudeAiOauth` object else
`badJSON`. Build the new config: existing config with the top-level
`oauthAccount` value replaced by the slot's object bytes (any value kind,
including `null`), or inserted before the closing brace (with a comma when
the object has members), or a new `{"oauthAccount":…}` when the file does not
exist. Then: `markInstall(n)` → write config (a failure here clears the mark
and rethrows: nothing was replaced yet) → `secrets.write(creds)` →
`clearMark` → `noteInstalled(n)`.

`isMixed` (kiba `CLAUDE-MIXED?`): `.installed` names slot S and S's
credentials file exists and the live identity reads and the live config does
NOT name S (email differs, or both orgs known and differ) and the live creds
bytes equal S's credentials bytes → true.

### Codex live login

```swift
public struct CodexLive {
  public init(paths: Paths, store: Store, root: URL? = nil)
  public func identity() throws -> Identity?     // nil when auth.json missing
  public func save(to n: SlotName) throws        // slot/auth.json = live bytes
  public func install(_ n: SlotName) throws      // identity must belong to n else mismatch; write live auth.json
}
```

### Usage records

```swift
public struct Limit: Codable, Equatable, Sendable { public var label: String; public var percent: Int; public var resetsAt: String }
public enum UsageState: String, Codable, Sendable { case ok, expired, revoked, error, unknown }
public struct UsageRecord: Codable, Equatable, Sendable {
  public var fetchedAt: Int          // epoch seconds
  public var state: UsageState
  public var note: String
  public var limits: [Limit]
}
```

`percent` is the whole number USED (0…100+). Percent rounding: decode the
JSON number as `Decimal` and round with `NSDecimalRound(.plain, scale 0)`.
Labels: `Session (5-hour)`, `Weekly (7-day)`, `<Model> Weekly` /
`<Model> Session` / `<Model>` for scoped windows. `resetsAt` is ISO 8601 or
"". `usage.json` is written through `JSONEncoder` (sorted keys) and
`PrivateFS.writePrivate`. A damaged usage file loads as
`UsageRecord(fetchedAt: 0, state: .unknown, note: "usage record is unreadable; refresh usage", limits: [])`.

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
the ChatGPT usage call, which sends `User-Agent: codex-cli`.

### Probing (port of sw-usage.f)

```swift
public struct ProbeInput { provider, name: SlotName, doc: Data /* slot loginFile bytes */, live: Bool }
public enum ProbeOutcome: Equatable { case record(UsageRecord, doc: Data /* possibly refreshed */); case revoked(note: String) }

public struct ClaudeProbe { init(http: HTTPClient, clock: Clock, lock: StoreLock, paths: Paths); func run(_ i: ProbeInput) async -> ProbeOutcome }
public struct CodexProbe  { same }
```

Claude:
1. Expired = `claudeAiOauth.expiresAt/1000 < now + 60`. If expired: live →
   `expired` "access token expired; Claude Code refreshes it on its next
   run"; no `refreshToken` → `expired` "…no refresh token is saved; log in
   again"; else refresh under the lock: POST
   `https://platform.claude.com/v1/oauth/token` JSON
   `{grant_type:"refresh_token", refresh_token, client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`.
   200 → splice `accessToken`, `refreshToken` (if returned), `expiresAt =
   (now+expires_in)*1000`, `refreshTokenExpiresAt` (if
   `refresh_token_expires_in`) into the doc and write the slot's
   credentials.json (still under the lock). 400/401 → `expired` "…the refresh
   was refused; log in again". Anything else / unreachable → `error`
   "Anthropic's token endpoint answered <code>" / "…could not be reached".
2. GET `https://api.anthropic.com/api/oauth/usage`, `Authorization: Bearer`,
   `anthropic-beta: oauth-2025-04-20`. 200 → limits: `five_hour` →
   Session; `seven_day_oauth_apps` else `seven_day` → Weekly (each bucket
   `{utilization, resets_at}`); then every `limits[]` entry with
   `scope.model.display_name` → `"<display_name> Weekly"` when `kind` starts
   with `weekly`, `"… Session"` for `five_hour`/`session`, bare name
   otherwise, `percent` from `percent`, reset from `resets_at`. State `ok`.
   401 → `expired` "login rejected by Anthropic; log in again". 429 → `error`
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
   epoch → ISO 8601 UTC. 401 on live → `expired` "access token rejected; run
   codex once to refresh it". 401 on saved → revokedFlag = body
   `error.code == "token_revoked"`; refresh under the lock: POST
   `https://auth.openai.com/oauth/token`
   `{client_id:"app_EMoamEEZ73f0CkXaXp7hrann", grant_type:"refresh_token", refresh_token}`;
   200 → splice `tokens.access_token`, `tokens.refresh_token`,
   `tokens.id_token` (each if returned), top-level `last_refresh` = ISO now,
   write slot auth.json; then GET again (200 → ok, else the 401/429/other
   notes below). Refresh refused (400/401): revokedFlag → `.revoked(note:
   "login revoked by a later `codex login`")`; else `expired` "access token
   rejected and the refresh was refused; log in again". Refresh other →
   `error` "OpenAI's token endpoint answered <code>". 429 → `error` "OpenAI
   is rate limiting usage checks; try again later". Other → `error` "OpenAI's
   usage endpoint answered <code>".

`fetchedAt` = now for every record.

### Switcher

```swift
public final class Switcher: Sendable {
  public init(paths: Paths, lock: StoreLock, http: HTTPClient, clock: Clock)
  public func save(_ p: Provider) throws -> SlotName?          // nil when no live login
  public func use(_ p: Provider, _ n: SlotName) async throws
  public func forget(_ p: Provider, _ n: SlotName) throws
  public func probeAll(_ p: Provider) async -> ProbeReport     // never throws
  public func importLogin(_ p: Provider, root: URL, claudeCreds: Data?) throws -> SlotName
}
public struct ProbeReport { public var saveBackError: String?; public var providerError: String?; public var accounts: [(SlotName, ProbeOutcome)] }
```

- `save`: under the lock: `installing` → `interrupted`; `isMixed` →
  `mixed`; identity nil → nil; else `liveName` + provider save.
- `use`: under the lock: save-back (skip silently when `installing`; skip
  when mixed; save when a live identity exists), install `n`; then, outside
  the lock, probe `n` as live and write its usage (under the lock).
- `probeAll`: under the lock: save-back (an error becomes
  `saveBackError`), scan. Then for every saved account, unlocked: read the
  slot doc, probe (`live` = name == live name); under the lock write
  `usage.json`, or on `.revoked` for a non-live account remove the slot.
  The live account is never refreshed and never removed.
- `importLogin`: reads the identity from the throwaway root (Claude: config
  at `root/.claude/.claude.json` and `claudeCreds` bytes; Codex:
  `root/.codex/auth.json`), `liveName`, saves under the lock. `noLive` when
  nothing is there.

### Status

```swift
public struct LiveLogin: Equatable, Sendable { public var email: String; public var plan: String }
public struct Account: Equatable, Sendable, Identifiable { public var name: SlotName; public var plan: String; public var active: Bool; public var usage: UsageRecord?; public var id: String { name.raw } }
public struct ProviderStatus: Equatable, Sendable { public var provider: Provider; public var live: LiveLogin?; public var accounts: [Account]; public var error: String? }
public struct Snapshot: Equatable, Sendable { public var providers: [ProviderStatus] }

public struct StatusReader { public init(paths: Paths); public func read() -> Snapshot }
```

Per provider, in this order so a broken live file still lists the saved
accounts: list slots (plan, usage); live identity; `active` = name ==
`liveName(live)`. Any throw becomes `error` (`reason`) with `live = nil`,
accounts kept. Never takes the lock.

### Rows (port of Panel.qml, pure)

```swift
public enum RowState: Sendable { case ok, tight, blocked, dead, unknown }
public enum Rows {
  static func isLong(_ label: String) -> Bool        // contains week|7-day|month|30-day (case-insensitive)
  static func session(_ u: UsageRecord?) -> Limit?   // first !isLong with percent ≥ 0
  static func weekly(_ u: UsageRecord?) -> Limit?    // first isLong with percent ≥ 0
  static func blocking(_ u: UsageRecord?) -> Limit?  // among percent ≥ 100: latest parseable reset, else the first
  static func headline(_ u: UsageRecord?) -> Limit?  // session ?? weekly
  static func dead(_ u: UsageRecord?, active: Bool) -> Bool   // revoked, or expired && !active
  static func state(_ u: UsageRecord?, active: Bool) -> RowState
  static func rank(_ s: RowState) -> Int             // ok 0, tight 1, blocked/dead 2, unknown 3
  static func sorted(_ a: [Account]) -> [Account]    // rank; rank 2 by blocking reset (unparseable last); else input order
  static func figures(_ u: UsageRecord?) -> [Figure] // session, weekly, then other percent ≥ 0 in order; each (label, left = 100 - percent)
  static func figuresText(_ u: UsageRecord?) -> String   // "limit" when blocked, else "72% · 40% · 9%"
  static func planText(_ a: Account, now: Date) -> String // "(pro)", "(pro, 5d)", "(pro, log in again)", ""
  static func tooltip(_ p: Provider, _ a: Account, now: Date) -> [String]
  static func resetShort(_ iso: String, now: Date) -> String  // "20m" | "5h" (<36h) | "2d"; "" unparseable
  static func resetLong(_ iso: String, now: Date) -> String   // "20 min" | "5 h 12 min" (<48h) | "3 days"
  static func age(_ epoch: Int, now: Date) -> String          // "just now" | "12 min ago"
  static func parseISO(_ s: String) -> Date?                  // ±offset, Z, any fractional digits
}
public struct Figure: Equatable { public var label: String; public var left: Int }
```

State: dead → `.dead`; no usage or no limits → `.unknown`; any percent ≥ 100
→ `.blocked`; headline left < 50 → `.tight`; any long window other than the
weekly with left < 50 → `.tight`; else `.ok`. Tooltip lines: `email · plan ·
current`; "Usage not probed yet" | note or "No limits reported" | one line
per limit `"<label>: 72% left · resets in 5 h 12 min"` (or "limit reached");
"Probed 12 min ago"; then "Click to log in to this account again" (dead) or
"Click to switch <title> to this account" (not active).

### Add account (LoginRunner)

```swift
public protocol TerminalLauncher: Sendable { func open(_ script: URL) throws }
public protocol KeychainLister: Sendable { func services(prefix: String) throws -> Set<String> }
public struct AddResult: Equatable { public var saved: SlotName; public var expected: String?; public var differs: Bool }
public actor LoginRunner {
  public init(paths: Paths, switcher: Switcher, terminal: TerminalLauncher, lister: KeychainLister, clock: Clock)
  public func add(_ p: Provider, expected email: String?) async throws -> AddResult
}
```

1. `claude`/`codex` must be on PATH (`noCLI`). Root = `paths.loginRoot(p)`:
   remove, create 0700, create `root/.claude` or `root/.codex`.
2. Claude only: snapshot `before = lister.services(prefix: keychainService)`
   and `liveBytes = KeychainItem.read()`.
3. Write `root/login.command` (0700):
   ```sh
   #!/bin/sh
   export CLAUDE_CONFIG_DIR="<root>/.claude"      # or CODEX_HOME="<root>/.codex"
   printf 'Sign in to %s at %s in your browser, then press Enter to continue: ' '<email or "the account to add">' '<site>'
   read -r _
   claude auth login --email '<email>'            # or: codex login   (no --email without one)
   rc=$?
   printf '%s' "$rc" > "<root>/exit.tmp" && mv "<root>/exit.tmp" "<root>/exit"
   if [ "$rc" -ne 0 ]; then printf '\nPress Enter to close\n'; read -r _; fi
   exit "$rc"
   ```
   Shell-quote every interpolated value. `terminal.open(script)`.
4. Wait for `root/exit` (directory watch via `DispatchSource`, plus a 1 s
   poll as belt and braces). Non-zero → `loginFailed`.
5. Locate the new credentials (Claude), in this order, first hit wins:
   a. `root/.claude/.credentials.json` exists → its bytes.
   b. `lister.services(prefix:) − before` non-empty → read that item, keep
      its bytes, delete the item.
   c. `KeychainItem.read() != liveBytes` → the login overwrote the live
      item: keep the new bytes, write `liveBytes` back (or remove when it
      was nil).
   d. → `loginProducedNothing`.
6. `switcher.importLogin(p, root, claudeCreds)`; probe the new slot
   (`live: false`) and write its usage; remove root. `differs` = expected
   email given and `saved.email != expected`.

The live login is never read by the provider's login command and never
revoked: the throwaway home guarantees that on Codex; on Claude the snapshot
restore in 5c covers a Keychain-writing login.

## KibaApp

### AppModel (`@MainActor @Observable`)

State: `snapshot: Snapshot`, `availability: .ready | .failed(String)`,
`refreshing`, `busy`, `message`, `error`, `panelOpen`, `autoProbed`, `now`
(ticks every 30 s while open), `cursor: ActionKey?`, `refreshIntervalSec`
(UserDefaults, default 120, min 15).

- `refresh(force:)`: skip when the last good read was < 5 s ago unless
  forced; coalesce when one is running; `StatusReader.read()` on a
  background task; success → snapshot, clear error; failure → availability
  failed, error = reason.
- Opening the panel: reset cursor, `autoProbed = false`, `refresh()`, then
  `maybeAutoProbe()` (once per open when any provider has saved accounts and
  nothing is busy); start the interval refresh and the clock tick. Closing
  stops both and clears `error`.
- Actions (`busy` guards all; each ends with `refresh(force: true)`;
  success message auto-clears after 4 s): `use(p, name)` — a dead row
  starts `add(p, name.email)` instead; `save(p)`; `add(p, email?)` closes
  the panel first; `probeUsage()` probes every provider; `forget(p, name)`
  (context menu, confirmed inline: the row turns into "Forget <email>?
  Forget / Keep").
- `actions: [ActionKey]` in panel order: every account row (`use`), `save`
  when the provider has a live login, no error and no active row, `add` per
  provider, `usage` at the end. The cursor tracks its key across refreshes.

### Status item and popover

`NSStatusItem` with a custom 18×18 image drawn by `GaugeIcon`. Left click
toggles an `NSPopover` (`.transient`, `NSVisualEffectView` `.popover`
material) hosting `PanelView`; right click shows a menu: Refresh usage,
Start at login (SMAppService toggle), Quit. `LSUIElement` true. The icon
tooltip lists `<title>: <live email or none>` per provider, or "AI accounts"
while unavailable.

### Visual design

Subject: allowance that drains and refills on a schedule. The panel's one job
is to answer "which account has room, and how much". Everything is native
material and system type except one signature and one risk.

Tokens (`Theme.swift`):

| token   | light      | dark       | use                                   |
|---------|------------|------------|---------------------------------------|
| `room`  | `#2E9E6B`  | `#4FC08A`  | ok rows, filled reservoir             |
| `low`   | `#C98A1E`  | `#E2A93B`  | tight rows                            |
| `out`   | `#C93B3B`  | `#E25555`  | blocked and dead rows, urgent icon    |
| `idle`  | secondary label color   | unknown rows, meta text            |
| `ink`   | label color             | names                                |
| `track` | quaternary label color  | empty reservoir                      |
| accent  | `Color.accentColor`     | the active account's name            |

Type: title in **New York** (`.system(size: 17, weight: .semibold, design: .serif)`)
— the one aesthetic risk, an editorial headline over a utility list;
eyebrows `11pt semibold, uppercase, tracking 0.8, idle`; names `13pt`
(`bold` when active); meta `11pt idle`; figures `11pt semibold,
monospacedDigit`, colored by state.

Layout (width 340, vertical padding 10, row inset 10):

```
┌──────────────────────────────────────────────┐
│ Room to work                 Probed 2 min ago│  title (serif) · meta
│ ──────────────────────────────────────────── │
│ CLAUDE CODE                                  │  eyebrow
│ ● joel@x.com (max)            72% · 40% · 9% │  name · plan · figures
│   ████████░░  ████░░░░░░  █░░░░░░░░░         │  reservoir
│ ● other@x.com (pro, 5d)               limit  │
│   ░░░░░░░░░░  ██████░░░░                     │
│   Save the current login                     │  action rows
│   Add account…                               │
│ CODEX                                        │
│ ● me@y.com (plus)                  88% · 61% │
│   █████████░  ██████░░░░                     │
│   Add account…                               │
│ ──────────────────────────────────────────── │
│ Refresh usage                    2 min ago   │
└──────────────────────────────────────────────┘
```

Signature — the **reservoir**: under every account row a 4 pt bar split
into one segment per window (session, week, each model window, in figure
order), 3 pt gaps, radius 2, track `track`, fill from the left = left/100 in
the row's state color. A used-up segment is an empty track; the reset
countdown lives in the plan text `(pro, 5d)`. The menu bar icon is the same
idea at 18 px: one thin vertical cell per provider, filled to the active
account's headline remaining, outline only when unknown; drawn `out` when
`error != nil`, at 50 % opacity when unavailable, otherwise the menu bar's
label color.

Rows: no boxes; a row highlights with `ink` at 10 % under the pointer or the
keyboard cursor, 5 % when active. Name elides in the middle; plan and
figures always fit. Blocked and dead names are `idle`; blocked figures read
`limit`; dead plan text carries "log in again". Unknown dots are 60 %
opacity. Motion: reservoir fills animate `easeOut(0.35)` on data change,
disabled under Reduce Motion. Hover shows the tooltip lines via `.help`.
Keyboard: ↑/↓ move the cursor (scrolling it into view), ⏎ activates, ⎋
closes; hover moves the cursor without scrolling.

Copy: "Room to work" (title), meta = "Working…" | "Refreshing…" | "Usage
probed 2 min ago" | "Saved logins" | "Unavailable"; "Not logged in" under a
provider without a live login; "Retry" row when status failed; error and
message text below the title (error in `out`, message in `idle`, max 3
lines). Action names stay the same through the flow: "Save the current
login" → "Saved joel@x.com"; "Switching Claude Code to other@x.com…" →
"Claude Code: now other@x.com".

## Build, bundle, test

- `swift build` / `swift test` from the package root; tests set
  `HOME`, `KIBA_STORE`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME` to a scratch
  directory per test and use `FileSecret`/`MemorySecret`, `StubHTTP`, a
  frozen clock. The one Keychain test uses service `kiba-mac-test-<uuid>`
  and deletes it in `defer`.
- `build.sh`: `swift build -c release`, assemble `build/Kiba.app`
  (`Contents/MacOS/Kiba`, `Info.plist`: `CFBundleIdentifier
  io.github.joelreymont.kiba`, `LSUIElement` true, `LSMinimumSystemVersion
  14.0`, `NSHighResolutionCapable`; `Resources/AppIcon.icns` rendered by
  `Scripts/icon.swift`), `codesign --force --sign -`, then copy to
  `~/Applications/Kiba.app` (replace via rename).
- `test.sh`: `swift test` with the scratch env exported (defence in depth).

## Store layout

```
~/Library/Application Support/kiba/
  lock/pid                  held only during writes
  probe/                    scratch: login-claude/, login-codex/
  claude/.installed         slot name whose files are live
  claude/.installing        marker while a two-file install is in flight
  claude/<name>/credentials.json
  claude/<name>/oauth-account.json
  claude/<name>/usage.json
  codex/<name>/auth.json
  codex/<name>/usage.json
```

Directories 0700, files 0600, every write temp + rename.

## Decisions and their reasons

- `/usr/bin/security` over the Security framework: Claude Code creates the
  item with `security`, so `security` is on its ACL and never prompts; a
  differently signed app would prompt on every rebuild and after every
  fresh login. The secret goes in on stdin under `setsid`, never in argv.
- Login through the provider's own command in Terminal: the OAuth flows are
  undocumented and change; the throwaway home keeps the live login out of
  reach, and the three-way credential detection covers every place a Claude
  login under `CLAUDE_CONFIG_DIR` may write.
- Store under Application Support, not `$XDG_DATA_HOME`: the macOS
  convention; there is no CLI to share the store with.
- No CLI, no Habu, no Forth: the app owns the logic; tests replace the
  Forth suite.
