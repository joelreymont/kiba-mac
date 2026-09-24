---
title: "UI lane: the whole KibaApp on a fixture backend"
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-24T13:20:54.117776+02:00\\\"\""
closed-at: "2026-09-24T13:47:00.670981+02:00"
close-reason: landed as vsuxwnuoltnr; swift build clean, bundle lint and codesign pass; user hands-on check pending
---

Everything under Sources/KibaApp plus Sources/KibaCore/Backend.swift, Usage.swift (Limit, UsageState, UsageRecord, usage.json codec), Status.swift (LiveLogin, Account, ProviderStatus, Snapshot), Rows.swift (port of Panel.qml per DESIGN.md 'Rows'); build.sh, test.sh, Scripts/icon.swift. Per DESIGN.md sections KibaApp, AppModel (Backend seam, FixtureBackend), Status item and popover, Visual design, Build. Gate: swift build warning-free; ./build.sh produces build/Kiba.app; the user launches it with KIBA_FIXTURE and sees the panel. No unit tests. Claim: agent=worker workspace=.jj-ws/pkg.
