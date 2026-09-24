---
title: "PanelView: visual design, reservoir, rows, actions"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.455264+02:00"
blocks:
  - kiba-mac-appmodel-status-item-348cdcab
---

Problem: the panel is unstyled. Acceptance: DESIGN.md 'Visual design' exactly: Theme tokens with light/dark values, New York title, eyebrows, name/plan/figures typography, row highlight and active tint, middle elision, ReservoirView (4 pt, segment per figure, 3 pt gaps, radius 2, fill = left/100 in state color, easeOut 0.35 animation honoring Reduce Motion), action rows with detail text, header meta strings, error/message block (max 3 lines), 'Not logged in' and provider error text, Retry row, footer Refresh usage with age, inline forget confirm. Width 340, scroll when taller than 600. Verify with screenshots in light and dark against a fixture snapshot (a SwiftUI preview or a debug env var KIBA_FIXTURE=<json> that loads a Snapshot from a file instead of the store). Files: Sources/KibaApp/Theme.swift, PanelView.swift, ReservoirView.swift, AccountRow.swift, ActionRow.swift, Fixture.swift. Verify: swift build; screenshots attached to the report. Depends: AppModel dot. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
