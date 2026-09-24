---
title: StoreLock and Store
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.343980+02:00"
blocks:
  - kiba-mac-privatefs-and-jsondoc-a315fc2e
  - kiba-mac-provider-paths-slotname-21508c16
  - kiba-mac-identity-parsers-for-72a04744
---

Problem: no store lock, slot listing, live-name resolution, or install markers. Acceptance: DESIGN.md 'StoreLock' and 'Store' exactly: mkdir mutex with pid file, stale takeover (dead pid via kill(pid,0)==ESRCH, or pid-less dir older than 60 s), non-reentrant precondition, release order; Store.list sorted by SlotName and only dirs holding loginFile, slotIdentity nil when damaged, slotPlan, liveName candidate walk with org matching and damaged-as-free, installed/noteInstalled/installing/markInstall/clearMark/removeSlot. Tests: lock held by a live pid throws locked; dead pid taken over; old pid-less dir taken over; fresh pid-less dir not; liveName picks the org-matching slot over a free earlier candidate; 'email #2' allocation; capacity at 10 logins; damaged slot repaired only when no other slot holds the org. Files: Sources/KibaCore/StoreLock.swift, Store.swift, Tests/KibaCoreTests/StoreLockTests.swift, StoreTests.swift. Verify: swift test. Depends: PrivateFS, Paths, Identity dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
