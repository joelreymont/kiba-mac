---
title: Tell when a re-login lands in another row
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-10-15T11:43:00.423137+03:00\\\"\""
closed-at: "2026-10-15T11:43:00.431798+03:00"
close-reason: "landed in 'Tell when a re-login lands in another row'; swift build warning-free, ./test.sh 69/69"
---

Problem: clicking a dead or throttled row logs in again with only its email (AppModel.use -> add(p, email: n.email)); LoginRunner saves the login under the row its organization maps to (Store.liveName) and compares emails only. hi@joel.id has two Claude organizations, both named "hi@joel.id's Organization", so two re-logins of hi@joel.id #2 silently refreshed hi@joel.id and #2 never changed. Claude Code cannot pin the organization per login (forceLoginOrgUUID is managed policy only; auth login has no org flag). Acceptance: add takes expected: SlotName?; differs = saved != expected; the app says 'Added hi@joel.id, not hi@joel.id #2' (held). Test: addClaudeFromFileAndFromKeychain re-logs k@y #2, lands in k@y, differs. Files: LoginRunner.swift, Backend.swift, CoreBackend.swift, AppModel.swift, IntegrationTests.swift, DESIGN.md. Verify: swift build warning-free; ./test.sh. Depends: none. Ownership: lead (birch), direct edit. Claim: agent=birch workspace=default.
