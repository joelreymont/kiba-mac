---
title: "LoginRunner: add account through the provider login in Terminal"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.432938+02:00"
blocks:
  - kiba-mac-switcher-save-use-ac4732ff
  - kiba-mac-subprocess-and-secretstore-9187e27e
---

Problem: no way to add an account. Acceptance: DESIGN.md 'Add account (LoginRunner)' exactly: throwaway root, login.command with shell-quoted values, TerminalLauncher (production: /usr/bin/open -a Terminal <script>), exit-file watch (DispatchSource + 1 s poll), loginFailed on non-zero, three-way Claude credential detection with Keychain snapshot restore, KeychainLister (production parses 'svce' attributes from security dump-keychain output, names only), importLogin, probe of the new slot, root removal, differs flag. Tests: a fake TerminalLauncher that runs the script with sh in the background against fake claude/codex executables on a scratch PATH writing credentials; cases a, b, c, d of the detection using MemorySecret-backed fakes; the restored live bytes; non-zero exit; script quoting with an email containing a quote. Files: Sources/KibaCore/LoginRunner.swift, Tests/KibaCoreTests/LoginRunnerTests.swift. Verify: swift test. Depends: Switcher, SecretStore dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
