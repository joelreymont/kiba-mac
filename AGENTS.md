# kiba-mac — AI account switcher for the macOS menu bar

Native Swift app: switches the live Claude Code and Codex CLI logins between
saved copies and shows how much of each saved account's allowance is left.
`DESIGN.md` is the contract: module interfaces, provider protocols, store
layout, UI spec. Read it before changing anything.

## Layout

- `Package.swift` — SwiftPM, macOS 14+, Swift 6 language mode.
- `Sources/KibaCore/` — store, identity, providers, probes, switching, row
  logic. No AppKit or SwiftUI imports. One concern per file, named after the
  DESIGN.md section (`Paths.swift`, `StoreLock.swift`, `ClaudeProbe.swift`…).
- `Sources/KibaApp/` — `AppModel`, status item, popover, `PanelView`,
  `Theme`, `GaugeIcon`.
- `Tests/KibaCoreTests/` — integration tests only: each test drives a real
  entry point (`Switcher`, `StatusReader`, `LoginRunner`, `AppModel`) on a
  scratch store with stubbed HTTP and a throwaway Keychain item, and checks
  what the user would see. No per-type unit tests; a module is proven by the
  flow that uses it.
- `Scripts/` — `icon.swift` (app icon renderer). `build.sh` builds and
  installs `~/Applications/Kiba.app`; `test.sh` runs the suite.
- Store: `~/Library/Application Support/Kiba` (or `$KIBA_STORE`): one
  SQLite file, `kiba.db`, local to this Mac and never shared.

## Rules

- Never read, write, or delete real credentials during development or
  tests: no `~/.claude.json`, `~/.claude/`, `~/.codex/`, no Keychain item
  other than `kiba-mac-test-*`, no provider endpoint with a real token, and
  no folder holding real saved accounts (the store, `~/.config/kiba`, or
  any old kiba-layout folder). Tests set `HOME`, `KIBA_STORE`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`
  to a scratch directory and use `FileSecret`/`MemorySecret`, `StubHTTP`, a
  frozen clock.
- Never run `claude auth logout` or `codex logout` from code or tests: both
  revoke tokens server-side and kill every saved copy.
- Never refresh the live account's token. Only a 400 or 401 from a token
  endpoint means a saved login is gone; anything else is `error`.
- Credential files and slot directories are 0600/0700 and replaced by
  temp + rename (`PrivateFS`). Login documents are rewritten by byte
  splicing (`JSONDoc`), never by re-serialising.
- Every request names `kiba` as User-Agent (the ChatGPT usage call keeps
  `codex-cli`).
- Every error is a `KibaError` with a one-line `reason`; nothing is logged
  and swallowed. Isolation happens only in `StatusReader` and
  `Switcher.probeAll`.
- Short names (2–3 words), no stubs, no TODOs, no dead code, no magic
  numbers: named constants.
- VCS is `jj`. One commit per feature or fix, 50-char imperative subject.
  Workers edit only inside their `.jj-ws/<dot>` workspace and never push.
- Track work as dots (`dot ready`, `dot show <id>`); close only when landed.
- Agents never launch the app, never run `open`, `osascript`, or
  `screencapture`, and never activate windows: every such call steals the
  user's focus or pops a Finder window. Verify bundles with `plutil -lint`,
  `codesign -dv`, and `ls`; the user runs the app.

## Verify

- `swift build` warning-free is every lane's gate; `swift test` runs the
  integration suite once it exists and must be green before any commit. If
  `TMPDIR` points at a missing directory (this machine can inherit a Linux
  path), `swiftc` fails with `couldNotFindTmpDir`: export a fresh one
  first, as `build.sh` and `test.sh` do.
- `./build.sh` produces `build/Kiba.app` and installs `~/Applications/Kiba.app`;
  `plutil -lint` and `codesign -dv` pass. The user runs it:
  `KIBA_FIXTURE=$PWD/Fixtures/demo.json ~/Applications/Kiba.app/Contents/MacOS/Kiba`.
- Read-only checks against the real store are fine (the app's status read).
  Never trigger switch, save, add, forget, or probe against the real HOME
  while testing.
