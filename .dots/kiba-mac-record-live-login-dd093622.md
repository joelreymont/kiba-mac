---
title: Record live-login switches in SQLite history
status: open
priority: 2
issue-type: task
created-at: "2026-10-26T12:13:10.805606+02:00"
---

Problem: history needs each switch's time and destination to attribute calls to accounts. Acceptance: design.md brief 2 as amended by amend.md (~/.cache/tmp/kibahist/): switch event appended inside each installer's completion transaction, details {}, use keeps its probe order; integration tests per brief 2 minus the origin, pre-install probe and refresh-before-install cases. Files: Sources/KibaCore/Switcher.swift, ClaudeLive.swift, CodexLive.swift, History.swift, DESIGN.md, Tests/KibaCoreTests/IntegrationTests.swift. Verify: ./test.sh. Depends: kiba-mac-record-usage-readings-3e118345. Ownership: those files. Claim: unassigned.
