---
title: "ClaudeProbe: usage and refresh"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.388517+02:00"
blocks:
  - kiba-mac-usage-status-types-9736bc68
  - kiba-mac-storelock-and-store-d17607c5
  - kiba-mac-privatefs-and-jsondoc-a315fc2e
---

Problem: no Claude usage probe. Acceptance: DESIGN.md 'Probing' Claude section exactly, every branch and note string; refresh splices tokens via JSONDoc and writes the slot credentials.json under the lock; live account never refreshed; scoped model windows labelled per spec; percent via Decimal .plain rounding; fetchedAt = now. Tests with StubHTTP: fresh token 200 payload with five_hour, seven_day_oauth_apps, and a scoped limits entry; seven_day fallback; expired live; expired no refresh token; refresh 200 then usage 200 (slot file updated byte-exact except the four fields); refresh 401 -> expired; refresh 503 -> error; usage 401/429/500; unreachable. Every request's headers asserted (Bearer, anthropic-beta, UA kiba, Accept). Files: Sources/KibaCore/ClaudeProbe.swift, Tests/KibaCoreTests/ClaudeProbeTests.swift. Verify: swift test. Depends: Usage/HTTP, StoreLock, PrivateFS/JSONDoc dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
