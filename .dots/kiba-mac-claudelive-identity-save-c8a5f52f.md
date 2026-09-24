---
title: "ClaudeLive: identity, save, install, mixed check"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.366371+02:00"
blocks:
  - kiba-mac-storelock-and-store-d17607c5
  - kiba-mac-subprocess-and-secretstore-9187e27e
  - kiba-mac-identity-parsers-for-72a04744
  - kiba-mac-privatefs-and-jsondoc-a315fc2e
---

Problem: no Claude save/install. Acceptance: DESIGN.md 'Claude live login' exactly, including config splice cases (replace existing value of any kind incl. null; insert before closing brace with/without comma; create file), marker bracketing with clear-on-config-failure, mismatch and badJSON checks, noteInstalled, isMixed truth table. Tests: every splice case byte-exact against an original with odd formatting; install writes creds through the injected SecretStore; interrupted install leaves .installing; isMixed true/false cases per DESIGN.md. Files: Sources/KibaCore/ClaudeLive.swift, Tests/KibaCoreTests/ClaudeLiveTests.swift. Verify: swift test. Depends: StoreLock/Store, SecretStore, Identity, PrivateFS dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
