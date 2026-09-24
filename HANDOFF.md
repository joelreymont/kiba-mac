# HANDOFF — kiba-mac

Restart point after a reboot. Read this whole file, then continue from
"Next steps". Nothing has been implemented yet; only investigation is done.

## The ask (user's words, in order)

1. Clone `joelreymont/kiba` (done: `~/Work/kiba`) and create a `kiba-mac`
   repo "following it" (this repo; not yet on GitHub).
2. Design and implement a replacement macOS widget written in Swift.
3. Design, orchestrate, review and merge using Opus agents; Opus 5.5 by
   default. The `worker` agent (`~/.claude/agents/worker.md`) already
   declares `model: opus`, `effort: xhigh`; pass `model: "opus"` on every
   Agent call (reviewers too).
4. "load your ui design skill to create the most beautiful macos widget
   ever. don't necessarily follow the qml" → load
   `frontend-design:frontend-design` before designing the panel.
5. "you don't need to run the CLI either if macos doesn't need that. i don't
   need the cli and never use it" → the Swift app owns all account logic
   natively. No Habu, no Forth, no `kiba` binary, no shelling out for status.
6. One user message was cut off at "make sure" — unknown remainder; ask if
   it matters, otherwise proceed.

## What kiba is (source of truth: `~/Work/kiba`, README.md + AGENTS.md)

Switches the live Claude Code and Codex CLI logins between saved copies and
shows how much of each saved account's allowance is left. On Linux: a Forth
CLI (`src/*.f`) plus an Omarchy/Quickshell QML bar widget
(`plugin/kiba/Status.qml` = model, `Panel.qml` = view). The QML is the
behavioural spec for the UI (row colors, ordering, figures, tooltips,
keyboard cursor); the Forth files are the spec for the account logic.

### Provider facts (verified from kiba sources + this Mac)

Claude Code (`claude` 2.1.281 here):
- Live identity: `~/.claude.json` key `oauthAccount`
  {emailAddress, organizationUuid, organizationName, displayName, ...}.
  With `CLAUDE_CONFIG_DIR` set, `.claude.json` lives inside that dir.
- Live tokens on macOS: **Keychain generic password, service
  `Claude Code-credentials`** (confirmed present via `security dump-keychain`
  names). Account attribute = the macOS username. Data = the same JSON as
  Linux `~/.claude/.credentials.json`:
  `{"claudeAiOauth":{accessToken, refreshToken, expiresAt(ms), scopes[],
  subscriptionType, ...}}`. `~/.claude/.credentials.json` does NOT exist
  here. Reading the item's data was **denied by the permission classifier**
  (credential exploration) — design against the documented shape, never
  read the real item during development/tests.
- Plan = `claudeAiOauth.subscriptionType`. Org = `oauthAccount.organizationUuid`
  (tells two logins under one email apart).
- Usage: `GET https://api.anthropic.com/api/oauth/usage`, headers
  `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`,
  `Accept: application/json`, `User-Agent: kiba` (curl's UA gets 429).
  Body: `five_hour` and `seven_day_oauth_apps` (fallback `seven_day`)
  buckets `{utilization (percent, float), resets_at (ISO)}`, plus `limits[]`
  entries `{kind: "weekly_scoped"|..., percent, resets_at,
  scope:{model:{display_name}}}` → labelled `"<Model> Weekly"`.
- Refresh (saved accounts only, never the live one): POST
  `https://platform.claude.com/v1/oauth/token`
  `{grant_type:"refresh_token", refresh_token, client_id:
  "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}` → access_token, refresh_token?,
  expires_in, refresh_token_expires_in. Expired = `expiresAt/1000 < now+60`.
  Only HTTP 400/401 from the token endpoint means the login is gone
  (`expired`); anything else is `error`. 401 on usage → expired; 429 → error.
- Login command kiba uses: `claude auth login [--email <e>]` with
  `CLAUDE_CONFIG_DIR=<throwaway>/.claude`. OPEN QUESTION: on macOS, does a
  login under a custom `CLAUDE_CONFIG_DIR` write the Keychain (same service
  name? suffixed?) or `<dir>/.credentials.json`? Was about to check with
  `strings $(readlink -f ~/.local/bin/claude) | grep 'Claude Code-credentials'`
  and `claude auth --help` — the user declined those commands at reboot
  time; re-run them after restart (they are read-only).

Codex (`codex-cli 0.156.1` here):
- Live login: `~/.codex/auth.json` (`CODEX_HOME` honored) keys
  `OPENAI_API_KEY, auth_mode, last_refresh, tokens{access_token, account_id,
  id_token, refresh_token}`. Identity from `id_token` JWT payload
  (base64url): `email`, `https://api.openai.com/auth`.`chatgpt_plan_type`
  (plan), `.chatgpt_account_id` (org). API-key login (no id_token) → slot
  name `api-key`, plan `apikey`, no usage.
- Usage: `GET https://chatgpt.com/backend-api/wham/usage`, Bearer
  access_token, `ChatGPT-Account-Id: <account_id>`, `User-Agent: codex-cli`.
  Body `rate_limit.primary_window` / `secondary_window`
  `{used_percent, limit_window_seconds, reset_at (epoch)}`; window
  ≤ 21600 s → "Session (5-hour)" else "Weekly (7-day)".
- Refresh: POST `https://auth.openai.com/oauth/token`
  `{client_id:"app_EMoamEEZ73f0CkXaXp7hrann", grant_type:"refresh_token",
  refresh_token}` → access_token, refresh_token?, id_token?; set
  `last_refresh` to ISO now. A 401 whose body `error.code ==
  "token_revoked"` AND a refused refresh (400/401) → state `revoked`, slot
  removed (saved accounts only).
- Login: `codex login` with `CODEX_HOME=<throwaway>/.codex`. Never run
  `codex logout` / `claude auth logout` (server-side revoke).

### Store semantics to keep (from kiba)
- Slot dirs `<store>/<provider>/<name>/`, dirs 0700, files 0600, every
  write via same-dir temp + rename. Name = email, or `email #2`, `#3`…
  matched by org, never by position. Claude slot: `credentials.json` +
  `oauth-account.json`; Codex slot: `auth.json`; each `usage.json`
  `{fetchedAt, state: ok|expired|revoked|error|unknown, note, limits[
  {label, percent(used, int), resetsAt}]}`.
- `use`: save back the live login first (tokens rotate), then install.
  Claude install writes two things; an install marker brackets them so an
  interrupted switch never files one account's tokens under another's name;
  a "mixed" live pair (config names A, tokens still byte-identical to
  installed slot B) is never saved back.
- Lock dir with owner pid, stale takeover, status never takes it.
- Store location on macOS: `~/Library/Application Support/kiba/`
  (decision; kiba uses `$XDG_DATA_HOME/kiba`).

### Widget behaviour (Panel.qml, keep semantics, redesign the look)
- Row state: dead (usage.state revoked, or expired && !active) →
  "log in again", click starts a login; blocked (any window ≥100%) → "limit"
  + reset countdown `(pro, 5d)`; tight (<50% of session/headline left, or
  any extra weekly window <50%); ok; unknown (no data, grey).
- Order: ok, tight, blocked/dead (by soonest reset, dead last), unknown;
  else name order. Figures: `session% · week% · model%` of what is LEFT.
- Tooltip per row: every window with % left and "resets in"; probed age;
  action hint. Panel: provider sections, "Save the current login" (only
  when the live login has no active slot), "Add account…", "Refresh usage"
  with age. Auto-probe every account once per panel open; refresh status
  while open (120 s default), not while closed. Keyboard cursor over rows.
  Bar icon color: urgent on error, dim when unavailable.

## Design decisions made so far

- Native Swift app, menu bar item (NSStatusItem + custom popover or
  MenuBarExtra window style), SwiftUI panel, macOS 14+ (this Mac: 26.5.1,
  Swift 6.3.2, Xcode CLT present). Swift Package + small `.app` bundle
  build script (no Xcode project needed; `swift build` + bundle assembly),
  `LSUIElement` true (no Dock icon).
- Layers: `KibaCore` (store, identity, providers, usage probes, switching;
  pure Swift, URLSession, fully testable with a scratch HOME/store and a
  stubbed HTTP + secret store) and `KibaApp` (UI). Keychain and HTTP behind
  protocols so tests never touch real credentials or the network.
- Claude Keychain access: either Security framework (`SecItemCopyMatching`
  / `SecItemUpdate`; one "Always Allow" prompt per build signature) or the
  same `/usr/bin/security` tool Claude Code itself uses (no prompts; but
  `add-generic-password -w <secret>` puts the secret in argv). Was testing
  whether `security add-generic-password -U` accepts the secret on stdin
  with a throwaway item `kiba-mac-probe-*` — user declined at reboot time;
  re-run that test (harmless, deletes its own item) and decide.
- "Add account": preferred = run the provider's own login (`claude auth
  login`, `codex login`) in Terminal with the throwaway home, then import
  from it (no hand-rolled OAuth; too many undocumented details). Depends on
  the Claude Keychain OPEN QUESTION above.

## Process rules in force

- Global `~/.claude/CLAUDE.md`: jj not git, `rg`, dots tracker (`dot`
  CLI, `.dots/`), workers in `.jj-ws/<id>` workspaces, hunk-by-hunk review
  + fresh-context destruction pass before merge, no stubs/TODOs, short
  names. Skills already read: jj, parallel-agents, dots, frontend-design.
- Never run `use`/`add`/`save`/`usage`-equivalents against the real HOME
  while testing; never call a provider endpoint with a real token by hand.
- `gh` is authenticated as joelreymont (repo, workflow scopes). Create the
  GitHub repo with `gh repo create joelreymont/kiba-mac --public --source .`
  once there is a first commit; MIT license like kiba.

## Next steps

1. Re-run the three declined read-only checks (claude binary strings,
   `claude auth --help`, `codex login --help`, `security` stdin test).
2. Write `DESIGN.md` (architecture, module interfaces, store/lock/marker
   protocol, provider adapters, UI spec from the frontend-design pass:
   palette, type, layout, signature element) and `AGENTS.md` (repo rules,
   build/test commands, verification steps).
3. `dot init`; add dots (<30 min each): package skeleton + app bundle
   script; store + atomic private writes + lock + marker; Claude identity +
   Keychain adapter; Codex identity; usage probes (Claude, Codex) with
   stubbed HTTP tests; switch (`use`) with save-back and marker; add-account
   flow; status model + ordering/state rules (port of Panel.qml logic, unit
   tested); menu bar item + panel UI; keyboard cursor + tooltips; README.
4. Dispatch `worker` agents (model opus) in `.jj-ws/<dot>` workspaces;
   review with opus reviewers + a fresh-context destruction pass; merge;
   retire workspaces; close dots; push to GitHub.
