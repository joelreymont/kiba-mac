---
title: "Core lane 2: HTTP and usage probes"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T13:20:54.123808+02:00"
---

HTTP.swift (HTTPClient, URLSessionClient, StubHTTP), ClaudeProbe, CodexProbe per DESIGN.md 'Probing'; codes against the Usage/Status types and StoreLock contracts in DESIGN.md (UI lane owns the type files; Core lane 1 owns StoreLock; reconcile at merge). Gate: swift build warning-free at merge. No unit tests. Depends: fs lane landed. Claim: unassigned.
