---
title: Sort rows by Fable, then 5-hour, then weekly limit
status: closed
priority: 2
issue-type: task
created-at: "2026-10-22T17:07:29.945372+03:00"
closed-at: "2026-10-22T17:10:37.874313+03:00"
close-reason: "landed: rank by Fable, 5-hour, weekly"
---

User (2026-10-22): panel rows sort (1) every window with room, ok then tight; (2) a model window (Fable) used up; (3) session used up, soonest reset first; (4) weekly used up, soonest reset first; then dead or no plan; unknown last. Rows.rank(u, active:) and Rows.sorted carry it; DESIGN.md Rows block matches. Acceptance: rowsSortRoomTightUsedUpThenDead sorts d c e b f a with f's weekly reopening before b's session; swift build warning-free; swift test green; Fable code-reviewer passes.
