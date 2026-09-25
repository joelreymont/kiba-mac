---
title: "Add reads only the throwaway profile's Keychain item"
status: open
priority: 2
issue-type: task
created-at: "2026-09-25T15:18:35.863318+02:00"
---

Problem: LoginRunner.claudeCreds/otherItems (Sources/KibaCore/LoginRunner.swift ~151-168) treat every Keychain item whose service starts with 'Claude Code-credentials' but the live one as a candidate for the throwaway login's tokens. A real item of another CLAUDE_CONFIG_DIR profile ('Claude Code-credentials-<hash>') that refreshes while the add's Terminal login waits reads as 'changed'; if it sorts before the throwaway item, importLogin files the new account's config with that profile's tokens and found.item?.remove() deletes that profile's real item. Found by the 2026-09-25 audit of the mediums lane (oracle core #16 area); older code, not in the lane. Acceptance: the add flow computes the one service name Claude Code derives from the throwaway config dir (find the derivation in the claude binary: rg -a for the service string and the hash of the config dir; the plain 'Claude Code-credentials' string was not found by a simple rg, so it is built from parts) and reads, snapshots and removes only that item; an integration test with a FakeKeychain holding a second real profile item that changes during the login proves the other item is neither imported nor removed. Files: Sources/KibaCore/LoginRunner.swift, Paths.swift, Tests/KibaCoreTests/IntegrationTests.swift, DESIGN.md. Verify: swift build warning-free; ./test.sh green. Depends: none. Ownership: LoginRunner.swift. Claim: unassigned.
