---
title: "Give a provider's turn to waiters in arrival order"
status: closed
priority: 1
issue-type: task
created-at: "2026-11-01T18:57:17.588007+02:00"
closed-at: "2026-11-01T19:55:35.581402+02:00"
close-reason: "Landed: waiters join turn-<provider>.queue/ (created then locked, rejoining when a waiter behind took the entry) and try the turn flock only with no live entry ahead; give-up and dead entries never hold the queue. Tests turnGoesToWaitersInArrivalOrder, goneWaiterNeverHoldsUpTheQueue; switchWaitsForTheProbeRefreshingIt now polls the queue."
---

Problem: a provider's turn goes to whichever waiter tries its flock first (100 ms LOCK_NB polls). On 2026-11-01 kiba CLI probes from waiting auto-switch sessions ran 13 rounds back to back (17:43-17:47); the app's probe, which waits without bound, could lose every race, so the panel stayed busy and Joel could not switch.
Requirement: waiters for a provider's turn, in any process, get it in the order they began waiting. A waiter whose process died, or that gave up (turnBusy, cancellation, error), never holds the queue. Exclusion stays the flock on paths.turn(p), so an older kiba binary still excludes and is excluded.
Acceptance: an integration test where the turn is held from outside, a Switcher operation starts waiting, and a second operation starts the instant the turn is free: the first waiter runs first (fails on the polling turn); a dead waiter's entry does not block an operation; swift build warning-free; ./test.sh green; DESIGN.md Switcher turn text and Store layout say what the code does.
