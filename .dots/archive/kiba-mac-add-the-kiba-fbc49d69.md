---
title: Add the kiba CLI with a cross-process turn
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-10-07T10:39:52.811472+02:00\\\"\""
closed-at: "2026-10-07T11:28:44.122101+02:00"
close-reason: "landed: kiba CLI, cross-process turn, installedAt"
---

Problem: the Claude Code auto-switch mod (norbert, Dotfiles) needs kiba status --json / usage <p> / use <p> <name>; a CLI probe or use beside the app can refresh one saved refresh token twice because Switcher's per-provider turn (Serial) is in-process only, killing the login.
Acceptance: Serial becomes an flock on paths.store/turn-<provider> held across network waits for every ops(p) caller; KibaCLI target installed by build.sh as ~/.local/bin/kiba; status --json = Snapshot Codable + per-limit left from Rows.figures + per-provider installedAt (epoch s or null, stamped only by the install's noteInstalled); usage prints nothing, exit 1 on saveBackError/providerError; exits 0/64/1 with KibaError reason on stderr; DESIGN.md and AGENTS.md updated; existing turn test passes through the flock; one CLI integration test (JSON left values incl. Claude session rule, installedAt, one 64, one 1).
Files: Package.swift, build.sh, Sources/KibaCore/{Paths,Switcher,LoginRunner,Store,Status,StatusReader,ClaudeLive,CodexLive}.swift, Sources/KibaCLI/main.swift, Tests/KibaCoreTests/IntegrationTests.swift, DESIGN.md, AGENTS.md.
Verify: swift build warning-free, ./test.sh green, ./build.sh then ls -l ~/.local/bin/kiba, plutil -lint, codesign -dv.
Depends: none. Ownership: birch (lead) integrates; worker edits only .jj-ws/<id>. Claim: birch.
