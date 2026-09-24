---
title: Provider, Paths, SlotName
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-24T12:47:51.298466+02:00\\\"\""
closed-at: "2026-09-24T13:16:11.931879+02:00"
close-reason: implemented, reviewed, revised on 8 findings, landed as ttrprwso; swift test green at d4d1d304
---

Problem: no path model or slot naming. Acceptance: DESIGN.md 'Provider', 'Paths', 'SlotName' exactly, including env precedence (KIBA_STORE, CLAUDE_CONFIG_DIR, CODEX_HOME, HOME), the throwaway root override, .claude.json placement rule, keychainService constant, NAME-OK? validation, email/suffix parsing, belongs(to:), ordering (different emails bytewise; same email by suffix with bare = 1, so 'a #2' < 'a #10'). Tests for every rule. Files: Sources/KibaCore/Provider.swift, Paths.swift, SlotName.swift, Tests/KibaCoreTests/PathsTests.swift, SlotNameTests.swift. Verify: swift test. Depends: none. Ownership: listed files. Claim: agent=worker workspace=.jj-ws/paths. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
