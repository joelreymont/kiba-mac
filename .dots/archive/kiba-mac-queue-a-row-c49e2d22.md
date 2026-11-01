---
title: Queue a row click while usage refreshes
status: closed
priority: 1
issue-type: task
created-at: "2026-11-01T18:57:11.558317+02:00"
closed-at: "2026-11-01T19:55:35.575055+02:00"
close-reason: "Landed: a row click during a probe supersedes what is held and queues its switch (latest click wins, the active row drops it; a relogin row reads Adding a <Provider> account once usage is refreshed…); it runs after the probe's reread, clearing nothing the probe produced. Tests appModelQueuesASwitchWhileUsageRefreshes, appModelDropsAQueuedSwitchOnTheActiveRow."
---

Problem: Joel (2026-11-01) could not switch Claude to deadbeef@joel.id from the panel: every row was greyed out. Opening the panel starts a usage probe; busy disables every control until it ends, and the app's probe waits without bound for the provider turn, which kiba CLI probes held back to back (13 rounds 17:43-17:47). Joel chose: "Queue the switch".
Requirement: while a usage probe runs (Refresh usage or the probe opening the panel starts), account rows stay clickable; a click or keyboard trigger on a row that is not active queues a switch to it (a later click replaces an earlier one) and the message line reads "Switching <Provider> to <name> once usage is refreshed…"; when the probe's run ends (after its reread), the queued switch runs as a click then would (use(p, n): an active row does nothing, a relogin row logs in again). Every other control stays disabled while busy, and rows stay disabled during every other action.
Acceptance: an AppModel integration test holds a probe in flight (HeldHTTP), clicks a saved row, sees the queued message and no switch, releases, and sees the switch land after the probe; swift build warning-free; ./test.sh green; DESIGN.md AppModel says what the code does.
