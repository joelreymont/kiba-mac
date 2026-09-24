---
title: "CodexLive: identity, save, install"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.377797+02:00"
blocks:
  - kiba-mac-storelock-and-store-d17607c5
  - kiba-mac-identity-parsers-for-72a04744
  - kiba-mac-privatefs-and-jsondoc-a315fc2e
---

Problem: no Codex save/install. Acceptance: DESIGN.md 'Codex live login' exactly: identity nil when auth.json missing, save copies live bytes to slot/auth.json, install checks the slot identity belongs to the name (mismatch) and writes live auth.json through PrivateFS (symlinked live file keeps the link), root override for the throwaway home. Tests for each. Files: Sources/KibaCore/CodexLive.swift, Tests/KibaCoreTests/CodexLiveTests.swift. Verify: swift test. Depends: StoreLock/Store, Identity, PrivateFS dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
