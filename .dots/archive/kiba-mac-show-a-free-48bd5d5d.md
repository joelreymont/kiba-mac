---
title: Show a free Claude account as free
status: closed
priority: 2
issue-type: task
created-at: "2026-10-15T12:33:19.964925+03:00"
closed-at: "2026-10-15T12:42:22.050160+03:00"
close-reason: "landed on main: a Claude usage 429 asks Anthropic's profile; no paid organization type records free and the row reads (free), else throttled as before; build warning-free, 69 tests green; Fable review ACCEPT, both Lows fixed (DESIGN no-organization wording, bearer assertion)"
---

Problem: laude@pm.me (Claude) went to the free plan after its saved profile was fetched (2026-10-02, organizationType claude_max). Anthropic answers its usage check with 429 "Rate limited. Please try again later.", which Kiba records as `throttled`: a grey "(max)" row offering a fresh login. Joel (2026-10-15): "it's a free account", "you already display some accounts as free, though", "for example cafebabe shows up as "free?""; chose the profile check.

Requirement:
1. On a usage 429, ClaudeProbe asks GET https://api.anthropic.com/api/oauth/profile with the same bearer (User-Agent kiba, as every non-usage, non-reset request). A 200 whose `organization` object has an `organization_type` Claude Code maps to no plan (anything but claude_max, claude_pro, claude_team, claude_enterprise) records new UsageState `free` with a note. Any other profile answer (paid type, no organization, non-200, unreachable) keeps `throttled` and the 429's note.
2. A `free` row looks like an unsubscribed one (RowState .unsubscribed: drained, cannot take work, counts as answered) with plan "free": "(free)" plan text and tooltip `email · free`. "(free?)" for refused refreshes and "(no plan)" for the 403 stay.
3. DESIGN.md says what the code does: Usage records, Claude probing step 2 (429), Rows, AppModel tally, colour table and accessibility text naming "no plan".

Acceptance: ProbeCase 429 cases carry a profile answer (paid → throttled, unreachable → throttled with the message, free → free, no extra request otherwise); rowsShowNoPlanWhenTheSubscriptionLapsed gains a saved account answered 429 + free profile that reads "(free)", counts as refreshed, and whose profile request named kiba; rowsOfferThrottledLoginAgain gets a paid profile answer. swift build warning-free, ./test.sh green.
