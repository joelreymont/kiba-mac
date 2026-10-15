---
title: Show a blank Claude login as log in again
status: closed
priority: 2
issue-type: task
created-at: "2026-10-15T12:10:33.591909+03:00"
closed-at: "2026-10-15T12:18:47.475050+03:00"
close-reason: "landed on main: a saved Claude login with no token records missing and reads (<plan>, log in again), live or saved, and is listed as failed; free? only for a refused saved login; build warning-free, 69 tests green; Fable review ACCEPT, both Lows fixed"
---

Problem: be46bd05 records a saved Claude login with no access token (or an expired one with no refresh token) as `expired`, so Rows.maybeFree labels it "(free?)". hi@joel.id #2 reads "(free?)" though it is on Max. Joel (2026-10-15): "hi@joel.id #2 shown as free but it's not"; chose "(max, log in again)" for blank logins only, refused refreshes keep "(free?)", blank logins listed in refresh notices.

Requirement:
1. New UsageState `missing`: the saved login holds no token to check or renew with. ClaudeProbe records it for Note.noToken and Note.noGrant. Codex unchanged.
2. Rows.dead counts `missing` whether or not the row is live (like `revoked`). Rows.maybeFree is a Claude record `expired` on a saved row only.
3. A `missing` row reads "(<plan>, log in again)", a click logs in again, and a refresh counts it failed with its note line.
4. DESIGN.md says what the code does: Usage records, Claude probing, Rows, AppModel tally.

Acceptance: ProbeCase blank and noRefresh record `.missing`; rowsShowRefusedClaudeLoginAsFree gains a blank login that reads "(max, log in again)" and is listed as failed. swift build warning-free, ./test.sh green.
