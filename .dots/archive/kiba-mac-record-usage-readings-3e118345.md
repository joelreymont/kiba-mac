---
title: Record usage readings in SQLite history
status: closed
priority: 2
issue-type: task
created-at: "2026-10-26T12:13:06.061529+02:00"
closed-at: "2026-10-26T12:40:17.232449+02:00"
close-reason: landed 282ccaa7; Astra major review ACCEPT; ./test.sh 70 pass
---

Problem: kiba.db keeps only each account's latest usage (Store.swift:48-105), so no report can tell which Claude account was live when or what a window percent costs. Acceptance: design.md brief 1 as amended by amend.md (~/.cache/tmp/kibahist/): user_version 5 history table, usage events appended in Switcher.record's transaction, integration tests listed there. Files: Sources/KibaCore/Store.swift, History.swift (new), Switcher.swift, DESIGN.md, Tests/KibaCoreTests/IntegrationTests.swift. Verify: ./test.sh. Depends: none. Ownership: those files. Claim: agent=worker workspace=.jj-ws.noindex/history
