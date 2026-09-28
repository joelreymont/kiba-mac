---
title: Open the app menu from the panel header
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-28T10:28:32.719751+02:00\\\"\""
closed-at: "2026-09-28T10:50:16.258566+02:00"
close-reason: "landed as dc41b4c2 on main: More button opens the app menu at the header; context-menu key override removed; build warning-free, 63 tests green at the integrated tip"
---

Problem: the app menu (Refresh usage, Start at login, Quit; Sources/KibaApp/StatusItem.swift `menu`) has no cursor-reachable control in the panel on macOS 14, and on macOS 15 KeyView.showContextMenuForSelection (Sources/KibaApp/KeyCatcher.swift) answers the system context-menu key by closing the panel and opening the app menu under the status item, which is not the focused row's context menu (AccountRow.row's .contextMenu offers Forget…), against AppKit's contract for that command. Oracle ui review 2026-09-28 (~/.cache/kiba-oracle/ui-review-2026-09-28.md) #8 and Medium 2.

Design (the contract):
1. The header (PanelView.header: title, meta) gains a trailing "More" control after the meta text: SF Symbol ellipsis.circle, styled like AddButton/DismissButton (plain button, Theme colors, the cursor fill), accessibility label "More", hint that it opens the app menu. It is a cursor target (new ActionKey case, e.g. .menu), first in cursor order (top of the panel), always enabled (the menu's own items enable themselves in menuWillOpen). A click and ⏎/Space on the cursor (model.trigger) do the same thing: the app menu pops up at the control (NSMenu.popUp(positioning:at:in:) anchored to the control's frame, below it), with the same NSMenu and menuWillOpen behaviour StatusItem has today. Mechanism is the worker's choice (pass the menu into PanelView from the status item, or an NSViewRepresentable anchor behind the SwiftUI button that installs an open closure on the model); AppModel must not own AppKit views.
2. Remove KeyView.showContextMenuForSelection and KeyCatcher's showMenu parameter; the system context-menu key falls through to the default (nothing selected, nothing opens). AppModel.showMenu becomes whatever the header control needs, or goes. The status item's VoiceOver custom action "Show Menu" stays.
3. DESIGN.md "Status item and popover": describe the header control and how keyboard, VoiceOver and mouse reach the menu on every supported macOS; drop the context-menu-key paragraph. "Visual design": header layout (title, meta, More) and Copy ("More"). Update the KeyCatcher and PanelView doc comments (KeyCatcher's key list).
4. Cursor order and the initial cursor position: the More control is first; the position the cursor takes when the panel opens does not change.

Acceptance (Tests/KibaCoreTests/IntegrationTests.swift, the existing AppModel integration style, no view tests): the cursor reaches the More control first and last in the wrap order the panel uses today; trigger on it runs the installed menu closure; forget/⌫ and the other keys are unchanged. swift build warning-free; ./test.sh green. No stubs, TODOs, dead code, magic numbers; short names.

Files: Sources/KibaApp/PanelView.swift, Sources/KibaApp/KeyCatcher.swift, Sources/KibaApp/AppModel.swift, Sources/KibaApp/StatusItem.swift, a new small view file if needed, DESIGN.md (the sections named), Tests/KibaCoreTests/IntegrationTests.swift.
Verify: export TMPDIR=$(mktemp -d /private/tmp/kiba-XXXXXX); swift build 2>&1 | grep -E 'warning|error|Build complete' (warning-free); ./test.sh (all green).
Depends: none.
Ownership: the files above, inside .jj-ws/<id> only. One commit, subject "Open the app menu from the panel header".
Claim: agent=worker-menu workspace=.jj-ws/kiba-mac-open-the-app-deb6e60d
