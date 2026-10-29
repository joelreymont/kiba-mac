---
title: Test sort order within a used-up limit
status: closed
priority: 2
issue-type: task
created-at: "2026-10-22T17:15:39.662808+03:00"
closed-at: "2026-10-29T17:03:14.435962+02:00"
close-reason: "landed: rowsSortRoomTightUsedUpThenDead; swift build clean, swift test 73/73"
---

User (2026-10-22): no pre-existing. rowsSortRoomTightUsedUpThenDead seeds two session-blocked and two week-blocked rows whose input order disagrees with their resets, plus an unparseable reset, so soonest-first and unparseable-last within ranks 3 and 4 are proven (fails with reset keying disabled).
