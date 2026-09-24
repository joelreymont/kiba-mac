---
title: Identity parsers for Claude and Codex
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.310290+02:00"
---

Problem: no way to tell who a login belongs to. Acceptance: DESIGN.md 'Identity' exactly: ClaudeIdentity.fromOAuthAccount/fromLive/planFromCreds; CodexIdentity.fromAuth with base64url JWT payload decoding (no padding, '-' '_' alphabet, reject bad input with badJSON), plan and org claims, api-key fallback, isAPIKey. Base64URL decoder is its own type with tests (padding-free lengths mod 4 = 2,3; invalid chars; dangling sextet rejected). Files: Sources/KibaCore/Identity.swift, Base64URL.swift, Tests/KibaCoreTests/IdentityTests.swift, Base64URLTests.swift. Verify: swift test. Depends: none (KibaError is in the base). Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
