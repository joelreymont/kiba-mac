---
title: Provider, Paths, SlotName
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.298466+02:00"
---

Problem: no path model or slot naming. Acceptance: DESIGN.md 'Provider', 'Paths', 'SlotName' exactly, including env precedence (KIBA_STORE, CLAUDE_CONFIG_DIR, CODEX_HOME, HOME), the throwaway root override, .claude.json placement rule, keychainService constant, NAME-OK? validation, email/suffix parsing, belongs(to:), ordering (different emails bytewise; same email by suffix with bare = 1, so 'a #2' < 'a #10'). Tests for every rule. Files: Sources/KibaCore/Provider.swift, Paths.swift, SlotName.swift, Tests/KibaCoreTests/PathsTests.swift, SlotNameTests.swift. Verify: swift test. Depends: none. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
