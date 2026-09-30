---
title: Show dead saved Claude logins as free?
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-30T12:02:39.729239+02:00\\\"\""
closed-at: "2026-09-30T12:15:00.633933+02:00"
close-reason: "landed on main: a dead saved Claude row (Rows.dead on Claude) reads (free?) and a refresh counts it as refreshed with no notice line; Codex and Claude error/on-hold unchanged; build warning-free, 67 tests green; Fable review: no High/Medium, Low Theme.out comment fixed"
---

Problem: two saved Claude logins (joelr1@gmail.com, olofi@pm.me) are dead: Anthropic refuses their refresh (400 invalid_grant: Refresh token not found or invalid). Their row reads "(max, log in again)" and every refresh holds a notice listing them as failed. Joel (2026-09-30): "can you just show the errored claude accounts as "free?", that's free with a question mark? otherwise, i get an error message every time i refresh". The answer carries nothing that proves the plan lapsed, hence the question mark.

Where it happens:
- Row text: Sources/KibaCore/Rows.swift `planText` (~157) appends Copy.again ("log in again") when `Rows.dead` (~72: record `revoked`, or `expired` on a non-live row); `Rows.plan` (~151) gives Copy.noPlan for `unsubscribed`. Rows has no provider today; `planText(_ a: Account, now:)` is called from the app with the provider in hand (tooltip already takes `_ p: Provider`).
- Refresh notice: Sources/KibaApp/AppModel.swift probe summary (~797): `.ok, .unknown, .unsubscribed` count as refreshed; `.expired` on a live account is waiting; `.expired, .error, .revoked` count as failed and add a line "Claude Code: <name>: <note>" that holds the notice.
- ClaudeProbe records a saved login as `expired` for Note.rejected (401 at usage), Note.noGrant and Note.refused(detail); it never records `revoked`.

Requirement (visible outcome; the worker designs within it):
1. A dead saved Claude row (Rows.dead on a Claude account: record `expired`, not live) shows plan text "(free?)" in place of "(<plan>, log in again)". Codex rows, live rows, and every other state keep their text.
2. A refresh that reaches such an account counts it as refreshed, like `unsubscribed`: no "failed" count, no notice line for it. A refresh where these are the only misses shows the plain "Usage refreshed for N accounts" notice. Codex `expired`/`error`/`revoked` and Claude `error` (including account_on_hold) are counted and listed as today.
3. Everything else unchanged: row colour (the "free?" text takes the colour "log in again" had), rank and sort, layout, figures, the tooltip (it keeps the recorded note with Anthropic's answer and its relogin line), click behaviour, the probe and what it records in the store. If the design needs any other visible change (tooltip header, VoiceOver wording beyond following the plan text), stop and report it instead of making it: Joel approves visual changes first.
4. DESIGN.md: "Rows" (planText/plan signatures and examples, State/plan wording, the Accessibility paragraph if it quotes the plan text), "AppModel" probe summary counting (~1024), and the Visual design colour table/paragraph that names "log in again" (~1119, ~1141, ~1230) say what the code now does. Short and exact, as the file writes.

Acceptance (Tests/KibaCoreTests/IntegrationTests.swift, through real entry points: AppModel for the notice, Rows/AppModel snapshot for the row text, as existing tests like appModelCountsProbeResults and rowsShowNoPlanWhenTheSubscriptionLapsed do):
- A saved Claude login whose refresh is answered 400 invalid_grant: its row's plan text is "(free?)"; a refresh over it (with a healthy account alongside) shows the plain refreshed notice with no failed count and no line naming it.
- A saved Codex login whose refresh is refused still reads "(<plan>, log in again)" and still counts as failed with its line (extend an existing test if one covers it rather than adding a duplicate).
- Existing tests stay green; update only those whose expected text this change alters.
- No per-type unit tests, no tautological or change-detector tests. No stubs, TODOs, dead code, magic strings: "free?" is a named constant in Rows.Copy. Short names.

Files: Sources/KibaCore/Rows.swift, Sources/KibaApp/AppModel.swift, Sources/KibaApp/AccountRow.swift (planText caller, ~88, only if the signature changes), DESIGN.md, Tests/KibaCoreTests/IntegrationTests.swift.
Verify: export TMPDIR=$(mktemp -d /private/tmp/kiba-XXXXXX); swift build 2>&1 | grep -E 'warning|error|Build complete' (warning-free); ./test.sh (all green).
Depends: none.
Ownership: the files above, inside .jj-ws/<id> only. One commit, subject "Show dead saved Claude logins as free?". Never touch real credentials, the real store, the Keychain or any endpoint; never launch the app; never push.
