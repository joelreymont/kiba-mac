---
title: "Send Claude Code's User-Agent on usage and reset calls"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-09-25T15:04:54.360218+02:00\""
closed-at: "2026-09-25T15:04:54.365605+02:00"
close-reason: implemented in the lead, swift build warning-free, ./test.sh 33 green, landed with this commit
---

Problem: the Claude usage endpoint answers kiba's User-Agent with ineligible_reason surface in both reset blocks, so no Claude reset is ever offered; the surface check on 2026-09-25 showed the CLI User-Agent alone turns cedar_ember.eligible true and x-app/anthropic-client-* change nothing. Acceptance: usage GET and reset POST carry claude-cli/<version> (external, cli); token refresh keeps kiba; tests assert the headers; DESIGN, AGENTS, README say the rule. Files: Sources/KibaCore/ClaudeProbe.swift, Tests/KibaCoreTests/IntegrationTests.swift, DESIGN.md, AGENTS.md, README.md. Verify: swift build warning-free; ./test.sh green. Depends: none. Ownership: ClaudeProbe.swift. Claim: agent=birch workspace=main
