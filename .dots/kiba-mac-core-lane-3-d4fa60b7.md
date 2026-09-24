---
title: "Core lane 3: switcher, add flow, wiring, integration suite"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T13:20:54.126851+02:00"
---

Switcher, LoginRunner (TerminalLauncher, KeychainLister), CoreBackend conforming to Backend, main.swift wiring (CoreBackend; delete EmptyBackend), and ONE integration suite driving Switcher/StatusReader/LoginRunner/AppModel on a scratch HOME (SQLite store under Library/Application Support) with StubHTTP, fake claude/codex executables, and a throwaway Keychain item; delete the landed per-type unit test files it supersedes. Gate: swift build, swift test green, ./build.sh. Depends: core lanes 1 and 2 and the UI lane landed. Claim: unassigned.
