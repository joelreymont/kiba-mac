---
title: AppModel, status item, popover shell, menus
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.444013+02:00"
blocks:
  - kiba-mac-pkg-skeleton-app-50de4630
  - kiba-mac-statusreader-e6989529
  - kiba-mac-switcher-save-use-ac4732ff
  - kiba-mac-row-state-ordering-c2bdf770
  - kiba-mac-loginrunner-add-account-8c8a8f3e
---

Problem: the app has no model or shell. Acceptance: DESIGN.md 'AppModel' and 'Status item and popover' exactly: observable state, refresh debounce/coalescing on a background task, open/close lifecycle (auto-probe once per open, interval refresh, 30 s clock tick), actions with busy guard and forced refresh, message auto-clear, actions list and cursor key tracking, forget with inline confirm state; NSStatusItem with left-click popover (transient, popover material) and right-click menu (Refresh usage, Start at login via SMAppService, Quit); tooltip text; PanelView may be a plain list at this point (the panel dot restyles it) but must show every row, action, message, and error from the model. Tests: AppModel unit tests with an injected StatusReader/Switcher fake (debounce, auto-probe once, action list composition, cursor retention). Files: Sources/KibaApp/AppModel.swift, StatusItem.swift, main.swift (replace stub), PanelView.swift, Tests/KibaAppTests/AppModelTests.swift (add target). Verify: swift test; ./build.sh and click through against the real store read-only (no switch/save/add). Depends: Package, StatusReader, Switcher, Rows, LoginRunner dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
