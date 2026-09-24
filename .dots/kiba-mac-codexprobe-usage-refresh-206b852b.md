---
title: "CodexProbe: usage, refresh, revocation"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.399626+02:00"
blocks:
  - kiba-mac-usage-status-types-9736bc68
  - kiba-mac-storelock-and-store-d17607c5
  - kiba-mac-privatefs-and-jsondoc-a315fc2e
---

Problem: no Codex usage probe. Acceptance: DESIGN.md 'Probing' Codex section exactly: api-key unknown; window labels by limit_window_seconds; reset_at epoch -> ISO UTC; 401 live -> expired; 401 saved -> refresh under lock (splice access/refresh/id tokens + last_refresh ISO now) then retry; token_revoked + refused refresh -> .revoked; refused without revoked flag -> expired; other refresh failure -> error; 429/other notes; ChatGPT-Account-Id header only when account_id present; UA codex-cli on usage, kiba on token. Tests with StubHTTP for every branch, headers asserted, slot file byte-exact except spliced fields. Files: Sources/KibaCore/CodexProbe.swift, Tests/KibaCoreTests/CodexProbeTests.swift. Verify: swift test. Depends: Usage/HTTP, StoreLock, PrivateFS/JSONDoc dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
