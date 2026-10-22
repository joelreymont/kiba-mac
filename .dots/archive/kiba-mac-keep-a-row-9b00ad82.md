---
title: Keep a row usable when only a model window is spent
status: closed
priority: 2
issue-type: task
created-at: "2026-10-22T16:53:06.036507+03:00"
closed-at: "2026-10-22T17:02:50.188439+03:00"
close-reason: landed
---

A Claude row whose Fable (or any model) window is used up but whose session and weekly windows have room reads red and limited. Only the session and weekly windows decide blocked; a spent model window makes the row tight (usable, sorted after rows with room everywhere). blocking() considers only those two windows. Acceptance: Rows.state/sorted/figuresText/planText per DESIGN; swift build warning-free; ./test.sh green.
