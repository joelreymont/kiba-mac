---
title: Show refused Claude logins as log in again
status: closed
priority: 2
issue-type: task
created-at: "2026-10-30T10:44:12.358233+02:00"
closed-at: "2026-10-30T10:49:46.253555+02:00"
close-reason: "landed on main: a refused saved Claude login reads (<plan>, log in again) and still counts as refreshed with no notice line; free? removed; test renamed rowsAskRefusedClaudeLoginQuietly; build warning-free, 74 tests green; Opus review PASS, Low Theme.out comment fixed"
---

Problem: joelr1@gmail.com (Max, paid until 2026-11-02) reads "(free?)": its saved refresh token expired (400 invalid_grant: Refresh token expired) and Rows.maybeFree labels every refused saved Claude login as a lapsed plan, which a refused refresh cannot show. Joel (2026-10-30): show "log in again", no notice: "don't pollute my nice list".
Requirement: a saved Claude row whose refresh Anthropic refused (record expired, not live) reads "(<plan>, log in again)" like every other dead row; a refresh still counts it as answered with no failed count or notice line. Rows.Copy.free and the "free?" text go; DESIGN.md (Rows, AppModel tally, colour table, accessibility) says what the code does.
Acceptance: rowsShowRefusedClaudeLoginAsFree becomes the log-in-again expectation and keeps the quiet notice; swift build warning-free, ./test.sh green.
