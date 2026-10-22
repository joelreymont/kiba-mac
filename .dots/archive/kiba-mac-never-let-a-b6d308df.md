---
title: Never let a model window decide a row
status: closed
priority: 2
issue-type: task
created-at: "2026-10-22T17:15:39.647090+03:00"
closed-at: "2026-10-29T17:05:29.992640+02:00"
close-reason: "landed: Rows decides by WindowLabel.session/weekly only; rowsKeepModelWindowsFromDeciding fails on old Rows; DESIGN.md Rows matches; swift build clean, swift test 74/74; one-lane change reviewed on Opus per routing rules (Fable not required), no findings"
---

User (2026-10-22): fix it. Rows took the first non-weekly / weekly-looking label as the session / weekly window, so with no account-wide reading a model's own window (Fable Session, Fable Weekly) decided the row: a used-up one showed 'limit' and blocked it. Deciding windows are now the exact WindowLabel.session / WindowLabel.weekly labels both probes write (the mod matches them the same way); isLong and its marks go. Acceptance: rowsKeepModelWindowsFromDeciding (fails on old code); DESIGN.md Rows matches; build warning-free; suite green; Fable code-reviewer passes.
