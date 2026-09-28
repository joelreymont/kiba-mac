---
title: Drop the More button from the panel header
status: closed
priority: 2
issue-type: task
created-at: "\"2026-09-28T11:29:25.183259+02:00\""
closed-at: "2026-09-28T11:29:25.208760+02:00"
close-reason: "landed on main: header back to one line, More button and MenuAnchor removed, context-menu key keeps AppKit's default; build warning-free, 66 tests green"
---

Problem: the menu lane (dot kiba-mac-open-the-app-deb6e60d) put a More button in the panel header to open the app menu and split the header into two lines (title + More, meta below) because title, meta and button exceed 308 pt on one line. Joel rejected it 2026-09-28: no visual design change without asking him first, no extra lines; the app menu was never required in the panel. Decision (Joel, agreed): remove the More button, MenuAnchor, ActionKey.menu and AppModel.showMenu; header back to one line, title with the meta at its right; keep the removal of KeyView.showContextMenuForSelection (the context-menu key keeps AppKit's default). The app menu opens from the status item and VoiceOver's Show Menu action. Files: Sources/KibaApp/PanelView.swift, AppModel.swift, StatusItem.swift, KeyCatcher.swift (doc), MenuAnchor.swift (removed), DESIGN.md (AppModel actions, Status item and popover, Visual design), Tests (appModelOpensTheMenuFromTheHeader removed, three order expectations restored). Verify: swift build warning-free; ./test.sh green.
