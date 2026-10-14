---
title: Name the sign-out that revokes a Codex login
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-10-14T16:50:34.578867+03:00\\\"\""
closed-at: "2026-10-14T16:51:17.911371+03:00"
close-reason: "landed in 'Name the sign-out that revokes a Codex login': note, comments and DESIGN.md mechanism; swift build warning-free, ./test.sh 69/69"
---

Problem: CodexProbe Note.revoked (CodexProbe.swift:226) says 'login revoked by a later codex login', but on 2026-10-14 three saved non-live logins died after Joel signed out of chatgpt.com; codex login only revokes the login in its own CODEX_HOME (rust-v0.162.1 login.rs:126-160). Acceptance: the note names the sign-out; comments (Probe.swift Fresh.stale, CodexProbe renewed, the revoked test's doc) and DESIGN.md Codex step 2 match; DESIGN.md records the mechanism and that adds keep the browser flow (Joel, 2026-10-14). Files: CodexProbe.swift, Probe.swift, IntegrationTests.swift, DESIGN.md. Verify: swift build warning-free; ./test.sh green. Depends: none. Ownership: lead (birch), direct edit. Claim: agent=birch workspace=default.
