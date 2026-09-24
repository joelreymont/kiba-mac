---
title: StatusReader
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.422384+02:00"
blocks:
  - kiba-mac-claudelive-identity-save-c8a5f52f
  - kiba-mac-codexlive-identity-save-c0d7efff
  - kiba-mac-usage-status-types-9736bc68
---

Problem: no snapshot of live and saved accounts. Acceptance: DESIGN.md 'Status' exactly: per-provider isolation (error string, live nil, accounts kept), slots listed before the live read, active by liveName, usage loaded per slot (damaged -> unknown note), never takes the lock (test: reader succeeds while the lock dir is held by a live pid). Tests: two providers, one with an unreadable live file; active detection with 'email #2' by org; api-key account. Files: Sources/KibaCore/StatusReader.swift, Tests/KibaCoreTests/StatusReaderTests.swift. Verify: swift test. Depends: ClaudeLive, CodexLive, Usage/Status types dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
