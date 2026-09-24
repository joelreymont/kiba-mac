---
title: "Core lane 2: HTTP and usage probes"
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-24T13:20:54.123808+02:00\\\"\""
closed-at: "2026-09-24T14:13:39.895891+02:00"
close-reason: "landed as mnzqnrry: HTTP client, Claude and Codex probes"
---

HTTP.swift (HTTPClient, URLSessionClient, StubHTTP), ClaudeProbe, CodexProbe per DESIGN.md 'Probing'; codes against the Usage/Status types in DESIGN.md; probes take no lock and never write. Gate: swift build warning-free at merge. No unit tests. Depends: fs lane landed. Claim: agent=worker workspace=.jj-ws/core2.
