---
title: Take the Codex plan from each usage check
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-10-14T16:14:55.565161+03:00\\\"\""
closed-at: "2026-10-14T16:22:11.006566+03:00"
close-reason: "landed in 'Take the Codex plan from each usage check': CodexProbe reads plan_type, setUsage writes it via coalesce; swift build warning-free, ./test.sh 69/69; Fable review accepted (empty plan_type finding rejected: codex PlanType is an enum, never empty)"
---

Problem: a saved Codex row's plan column is written only by Tx.put (save-back or add) from the id_token claim chatgpt_plan_type (Sources/KibaCore/Identity.swift CodexIdentity). Probes never touch it: Switcher.record (Switcher.swift:266) runs setUsage and setLogin only, and CodexProbe ignores the plan_type member of the wham/usage 200 answer. So an account upgraded after its login (joelr1@gmail.com, free -> plus/pro) keeps showing (free) until the user logs in again.
Acceptance: ProbeOutcome gains plan: String? (nil when the answer names none; default nil so ClaudeProbe is unchanged). CodexProbe's 200 path sets it from the answer's top-level plan_type when present (codex rust-v0.162.1 codex-backend-openapi-models RateLimitStatusPayload.plan_type). Tx.setUsage (its one caller is Switcher.record) takes plan: String? and runs SET usage = ?, plan = coalesce(?, plan). Save-back keeps writing the id_token claim; the probe that follows in the same run wins. DESIGN.md: ProbeOutcome line, Codex step 2 (plan_type -> plan), Tx setUsage line, Switcher write line. Test: switchSavesBackAndInstalls answers a@y's usage with plan_type pro over its saved plus and expects Account plan pro; b@y's answer has no plan_type and keeps pro.
Files: Sources/KibaCore/Backend.swift, CodexProbe.swift, Store.swift, Switcher.swift, DESIGN.md, Tests/KibaCoreTests/IntegrationTests.swift.
Verify: swift build warning-free; ./test.sh green.
Depends: none. Ownership: lead (birch), direct edit. Claim: agent=birch workspace=default.
