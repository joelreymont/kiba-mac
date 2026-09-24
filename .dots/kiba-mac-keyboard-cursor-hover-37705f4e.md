---
title: Keyboard cursor, hover, tooltips, scroll into view
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.466590+02:00"
blocks:
  - kiba-mac-panelview-visual-design-5d3016c7
---

Problem: no keyboard or hover behaviour. Acceptance: DESIGN.md 'Visual design' keyboard paragraph and AppModel cursor: up/down move the cursor and scroll it into view (ScrollViewReader), return activates, escape closes, hover moves the cursor without scrolling, cursor key survives a refresh, .help tooltips with Rows.tooltip lines on account rows, pointing-hand cursor on enabled rows only, disabled look while busy. Tests: AppModel cursor movement bounds and key retention. Files: Sources/KibaApp/PanelView.swift, AccountRow.swift, ActionRow.swift, KeyCatcher.swift, Tests/KibaAppTests/CursorTests.swift. Verify: swift test; manual check listed in the report. Depends: PanelView dot. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
