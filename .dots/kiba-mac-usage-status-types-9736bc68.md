---
title: Usage, status types, and HTTP client
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.321499+02:00"
blocks:
  - kiba-mac-privatefs-and-jsondoc-a315fc2e
  - kiba-mac-provider-paths-slotname-21508c16
---

Problem: no usage record, status, or HTTP abstraction. Acceptance: DESIGN.md 'Usage records', 'HTTP', and the Status types (LiveLogin, Account, ProviderStatus, Snapshot) exactly: Codable UsageRecord with sorted-key JSONEncoder and PrivateFS write helper usageWrite/usageLoad (damaged file -> the unknown record with the fixed note), Decimal .plain rounding helper percent(from: Decimal), ISO 8601 UTC formatting of an epoch; HTTPRequest/HTTPResponse/HTTPOutcome/HTTPClient, URLSessionClient (ephemeral, 20 s timeout, no cookies/cache, delegate refuses cross-host redirects), StubHTTP (scripted queue keyed by URL+method, records requests). Tests: rounding at .5 and .49, damaged usage file, StubHTTP recording; URLSessionClient tested against a local in-process HTTP server (Network framework NWListener on 127.0.0.1). Files: Sources/KibaCore/Usage.swift, Status.swift (types only), HTTP.swift, Tests/KibaCoreTests/UsageTests.swift, HTTPTests.swift. Verify: swift test. Depends: PrivateFS dot (usage write), Paths dot (SlotName in Account). Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
