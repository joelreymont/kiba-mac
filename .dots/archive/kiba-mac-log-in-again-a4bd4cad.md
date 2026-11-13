---
title: Log In Again in the account row menu
status: closed
priority: 2
issue-type: task
created-at: "2026-11-13T11:11:08.835060+02:00"
closed-at: "2026-11-13T11:35:11.931494+02:00"
close-reason: "Landed: 'Log In Again…' in the context menu of every account row but the live one, above a divider and Forget, and ⌘L on the cursor's row; AppModel.relogin refuses the live row and goes through one row-action queue with clicks, so during a probe it queues (latest wins) and runs after the reread on the row as it reads then. Test appModelQueuesALoginAgainWhileUsageRefreshes."
---

Add 'Log In Again…' to an account row's context menu, above Forget… with a divider, on every row but the live one; it starts add(p, name) as a click on a Rows.relogin row does (Terminal login in its own root, live login untouched). AppModel.relogin(p, name) reads the row when it runs and refuses the live one; ⌘L on the cursor's row (reloginCursor) reaches it from the keyboard, named in the VoiceOver hint of a row a press switches. While a probe runs it queues like a row click (Joel chose 'Queue it' 2026-11-13): one pending row action, latest wins, run after the probe's reread on the row as it reads then; disabled during every other action. Test: appModelQueuesALoginAgainWhileUsageRefreshes. DESIGN.md: document it beside Forget and in Keyboard. User asked 2026-11-13: a menu option on each item to log in again without clicking (which switches).
