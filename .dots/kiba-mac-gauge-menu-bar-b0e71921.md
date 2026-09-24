---
title: Gauge menu bar icon and app icon
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.477581+02:00"
blocks:
  - kiba-mac-appmodel-status-item-348cdcab
---

Problem: the status item shows text. Acceptance: DESIGN.md icon paragraph: GaugeIcon renders an 18x18 NSImage with one vertical cell per provider filled to the active account's headline remaining (outline only when unknown), colored out on error, 50% opacity when unavailable, label color otherwise, redrawn on every snapshot change and on appearance change; Scripts/icon.swift renders the app icon (the same reservoir mark, 1024 px) to PNGs and build.sh runs iconutil into Resources/AppIcon.icns and sets CFBundleIconFile. Tests: GaugeIcon fill levels for fixture snapshots (pixel sampling). Files: Sources/KibaApp/GaugeIcon.swift, StatusItem.swift, Scripts/icon.swift, build.sh, Tests/KibaAppTests/GaugeIconTests.swift. Verify: swift test; ./build.sh; screenshot of the menu bar. Depends: AppModel dot. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
