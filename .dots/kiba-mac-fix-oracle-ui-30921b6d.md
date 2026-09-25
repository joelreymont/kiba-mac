---
title: "Fix oracle UI items #2,#7,#9-#14 (a11y, layout, gauge, notices)"
status: active
priority: 2
issue-type: task
created-at: "\"2026-09-25T14:48:28.811033+02:00\""
---

Problem: oracle UI review ~/.cache/kiba-oracle/ui-review-2026-09-24.md items 2 (row a11y label/value), 7 (row fallback layout), 9 (gauge unknown vs zero vs error), 10 (probe notice overstates success), 11 (freshness label hides stale rows), 12 (login item requiresApproval), 13 (notices vanish, no announcement), 14 (Add buttons lack provider, titles not headings). Acceptance: each verified against the code and fixed or rejected with a reason; model-side items (9, 10, 11, 13) proven by AppModel integration tests failing before and passing after; view items by warning-free build; DESIGN.md UI spec updated. Files: Sources/KibaApp/*.swift, DESIGN.md, Tests/KibaCoreTests/IntegrationTests.swift, small KibaCore types only if AppModel needs them. Verify: swift build warning-free; ./test.sh green. Depends: none. Ownership: Sources/KibaApp; not Switcher/ClaudeLive/Store/Probe/JSONDoc/SecretStore/LoginRunner. Claim: agent=ui workspace=.jj-ws/ui
