---
title: Say why Anthropic rate limits a usage check
status: closed
priority: 2
issue-type: task
created-at: "2026-10-15T11:43:43.993888+03:00"
closed-at: "2026-10-15T11:43:44.009150+03:00"
close-reason: "landed in 'Say why Anthropic rate limits a usage check'; swift build warning-free, ./test.sh 69/69"
---

Problem: laude@pm.me's Claude row reads 'rate limiting' at 11:31 and 11:37 on 2026-10-15 although its token was renewed at 11:25 and rows checked just before and after it answered 200; the probe drops the 429 answer's body, so neither the user nor Kiba can tell which limit hit or whether a fresh login helps. Acceptance: a usage 429 note carries the answer's error.message on one line in parentheses; unchanged when absent. Test: a ProbeCase with a two-line message. DESIGN.md Claude step 2. Files: ClaudeProbe.swift, IntegrationTests.swift, DESIGN.md. Verify: swift build warning-free; ./test.sh. Depends: none. Ownership: lead (birch), direct edit. Claim: agent=birch workspace=default.
