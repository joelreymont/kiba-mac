---
title: Row state, ordering, figures, tooltips
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.332394+02:00"
blocks:
  - kiba-mac-usage-status-types-9736bc68
  - kiba-mac-provider-paths-slotname-21508c16
---

Problem: the widget's row logic (Panel.qml) has no Swift port. Acceptance: DESIGN.md 'Rows' exactly, every function, with the QML in ~/Work/kiba/plugin/kiba/Panel.qml as the reference for edge cases (resetShort thresholds 60 min / 36 h, resetLong 48 h, rounding, blocking limit picks the latest parseable reset, sorted keeps input order within a rank, tight when any extra long window is under half). parseISO accepts Z, +00:00, -05:30, and any number of fractional digits. Tests with a frozen now cover every branch and the sort order across all five states. Files: Sources/KibaCore/Rows.swift, Tests/KibaCoreTests/RowsTests.swift. Verify: swift test. Depends: Usage/Status types dot, Paths dot. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
