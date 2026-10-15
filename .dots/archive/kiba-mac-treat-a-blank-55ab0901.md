---
title: Treat a blank Claude login as needing a login
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-10-15T11:40:13.711133+03:00\\\"\""
closed-at: "2026-10-15T11:41:03.214567+03:00"
close-reason: "landed in 'Treat a blank Claude login as needing a login'; swift build warning-free, ./test.sh 69/69"
---

Problem: saved Claude row hi@joel.id #2 holds accessToken "", refreshToken "", expiresAt 0. ClaudeProbe.fresh skips refresh for expiresAt 0 and accessToken() accepts "", so the probe sends an empty Bearer; Anthropic answers 429 and the row reads 'rate limiting' (state throttled), hiding that the login is gone. Acceptance: an empty accessToken or refreshToken counts as absent; no access token -> expired 'no access token saved; log in again' with no request sent, so the row is dead and a click logs in again. Test: a ProbeCase with a blank Claude doc, no answers, expired + that note. DESIGN.md Claude step 2 last sentence. Files: ClaudeProbe.swift, IntegrationTests.swift, DESIGN.md. Verify: swift build warning-free; ./test.sh. Depends: none. Ownership: lead (birch), direct edit. Claim: agent=birch workspace=default.
