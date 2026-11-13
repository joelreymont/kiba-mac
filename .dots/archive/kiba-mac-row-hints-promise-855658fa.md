---
title: Row hints promise the click use() makes
status: closed
priority: 2
issue-type: task
created-at: "2026-11-13T11:22:01.824177+02:00"
closed-at: "2026-11-13T11:35:12.116922+02:00"
close-reason: "Landed: Rows.relogin requires !active, so the live row's tooltip promises no click use() ignores; AccountRow.speechHint keys on Rows.relogin, so a throttled row's hint says it logs in again. DESIGN.md says both."
---

Rows.relogin is true on the live row when its record is revoked or missing, so its tooltip reads 'Click to log in to this account again' while use() ignores the active row; and AccountRow.speechHint keys on state == .dead, so a throttled saved row's VoiceOver hint says 'Switches…' while a click logs in again. Fix: Rows.relogin requires !active (a click on the live row does nothing); speechHint keys on Rows.relogin. DESIGN.md relogin line says the same. Found by the Log In Again review 2026-11-13.
