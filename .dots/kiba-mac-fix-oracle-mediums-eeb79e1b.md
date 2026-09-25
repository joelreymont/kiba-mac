---
title: "Fix oracle Mediums #9-#16 minus store items (parsing, secrets)"
status: active
priority: 2
issue-type: task
created-at: "\"2026-09-25T14:48:28.807267+02:00\""
---

Problem: oracle core review ~/.cache/kiba-oracle/core-review-2026-09-24.md items 9 (Probe.swift setting drops absent members), 10 (JSONDoc accepts malformed JSON), 11 (JSONFields percent loses decimal precision), 13 (SecretStore/PrivateFS.exists hides fs errors), 15 (Keychain no-prompt guarantee overclaimed), 16 (LoginRunner Keychain listing misses hex attributes). Acceptance: each item verified against the code and fixed at the responsible layer with an integration test that fails before and passes after, or rejected with a one-line reason; DESIGN.md updated. Files: Sources/KibaCore/Probe.swift, JSONDoc.swift, JSONFields.swift, SecretStore.swift, PrivateFS.swift (inspection only), LoginRunner.swift, Tests/KibaCoreTests/IntegrationTests.swift, DESIGN.md. Verify: swift build warning-free; ./test.sh green. Depends: none. Ownership: the files above; not Switcher/ClaudeLive/Store/KibaApp. Claim: agent=mediums workspace=.jj-ws/mediums
