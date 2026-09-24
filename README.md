# Kiba

Switch the live Claude Code and Codex CLI logins between saved accounts, and
see which account still has room, from the macOS menu bar.

## Why

Claude Code and Codex each keep exactly one login on disk. Cycling through
several subscriptions means re-running the browser login every time a limit
hits, and guessing which account to switch to next. Kiba keeps a private copy
of each login, puts the chosen one back in place with one click, and asks
each provider how much of every saved account's allowance is left.

## Requirements

- macOS 14 or later, the Xcode command line tools, and the `claude` and
  `codex` CLIs you already use.

## Install

```sh
./build.sh          # builds build/Kiba.app and installs ~/Applications/Kiba.app
```

Launch Kiba from Spotlight or Finder; it lives in the menu bar and has no
Dock icon. Add it to Login Items yourself if you want it back after a
restart. Start with "Save the current login" under each provider so the
logins you have now are kept.

To add another account, sign into it at claude.ai or chatgpt.com in your
browser, then use "Add account…". A Terminal window opens, reminds you to
sign into the account in the browser and waits for Enter, because the
provider's login page authorizes whichever account the browser is signed
into. The login runs against a throwaway home, so the live login is never
read, replaced or revoked. Kiba saves what comes back under that account's
email and, when you named an account, tells you if a different one came
back. Adding never switches; switch with a click.

Never run `claude auth logout` or `codex logout`: both revoke the tokens
server-side and the saved copy dies with them. Kiba never runs either.

## The panel

One section per provider. Each saved account is a row: the email, the plan,
and what is left of the session, the week, and each model window, as
percentages in that order. Under each row a bar with one segment per window,
filled to what is left: green with half or more, amber under half, empty
when the window is used up. A used-up account reads `limit` and its label
carries the reset time, as in `(pro, 5d)`. A dead login reads "log in
again" and starts a login for that email when clicked. Hovering a row shows
every window with what is left and when it resets.

Rows are ordered by room: accounts with room first, then tight, then used
up or dead (soonest reset first), then never probed. The live account is
bold. Click a row to switch. "Save the current login" appears when the live
login is not yet saved; "Add account…" sits under each provider; "Refresh
usage" at the bottom probes every account, which also happens once each time
the panel opens. Right-click a row for "Forget…", confirmed in the row.

The menu bar icon is one thin cell per provider, filled to the live
account's headline remaining. Arrow keys move, Return activates, Escape
closes.

## How switching works

- **Claude Code**: the login is the credentials document Claude Code keeps in
  the Keychain (item `Claude Code-credentials`; a `.credentials.json` file
  under the config directory takes precedence when present) plus the
  `oauthAccount` object inside `~/.claude.json`. A switch rewrites the
  Keychain item and splices `oauthAccount` into the existing `~/.claude.json`,
  leaving every other byte untouched. Running sessions pick the new login up
  on their own. `CLAUDE_CONFIG_DIR` is honored. The Keychain item is read and
  written through `/usr/bin/security`, the tool Claude Code itself uses, so
  Kiba never triggers a Keychain prompt.
- **Codex**: the login is `~/.codex/auth.json`. Email and plan come from the
  `id_token` claims inside it. A switch rewrites the file; a running Codex TUI
  keeps its old tokens until restarted. `CODEX_HOME` is honored. An API-key
  login has no email; it is saved under the fixed name `api-key`.
- **Two logins under one email** (a second Claude organization or a second
  ChatGPT workspace) get separate rows in the order they are added: the first
  keeps the bare email, the next are `email #2`, `email #3`. A login is
  matched to its row by organization, never by position.
- **Save-back**: both CLIs rotate tokens while they run, so before installing
  another account Kiba first saves the live login into its own row. A saved
  copy is never staler than the last switch away from it. Kiba records which
  row it installed last; if `~/.claude.json` later names another account
  while the credentials are still the installed row's, the pair is mixed,
  save-back leaves it alone, and the panel says so.
- **Live files that are symlinks** stay symlinks: the write replaces the
  file the link points at.

## Usage per account

For every saved account Kiba asks the provider's usage endpoint with that
account's saved token:

- Claude: `GET https://api.anthropic.com/api/oauth/usage`. Windows:
  `Session (5-hour)`, `Weekly (7-day)`, and every model-scoped window the
  payload lists, named after the model, such as `Fable Weekly`.
- Codex: `GET https://chatgpt.com/backend-api/wham/usage`. Windows are named
  from their length: five hours is the session, seven days the week.

A saved account whose token has expired (Claude) or is rejected (Codex) is
refreshed once through the provider's token endpoint and the new tokens
replace the saved ones. The live account is never refreshed by Kiba: its CLI
owns that token, and rotating it underneath a running session would log the
session out. Only a 400 or 401 from a token endpoint means a saved login is
gone; a Codex login the provider reports as revoked is removed, and any other
failure is kept as that account's note. Every request names `kiba` as its
User-Agent (the ChatGPT usage call keeps `codex-cli`). Nothing leaves the
Mac except these calls.

## Where things live

`~/Library/Application Support/Kiba/kiba.db`, one SQLite file, mode 0600 in a
0700 folder, holding every saved login, its profile and its last usage
reading. It is local to this Mac and never shared. The live files stay where
the CLIs read them and are replaced through a same-directory temp file and
rename.

## Build and test

```sh
swift build     # warning-free is the gate
./test.sh       # the integration suite in a scratch HOME; never touches real logins
./build.sh      # the app bundle, ad-hoc signed, installed to ~/Applications
```

[DESIGN.md](DESIGN.md) is the contract for every module.

## License

[MIT](LICENSE).
