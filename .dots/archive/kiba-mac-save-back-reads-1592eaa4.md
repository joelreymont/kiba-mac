---
title: Save-back reads the live login once
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-25T15:30:44.020679+02:00\\\"\""
closed-at: "2026-09-25T15:34:24.959115+02:00"
close-reason: "landed as lqtvsukx 'Read the live login once when saving it': Switcher.put reads LoginRead once and writes it; swift build warning-free, 48 tests green"
---

Problem: Switcher.put (Sources/KibaCore/Switcher.swift:186-193) reads files.identity() (one read of the live config and credentials), then inside store.write calls files.save(to:) (ClaudeLive.swift:38-45, CodexLive.swift:27-32), which rereads the files and only checks that the slot belongs to the email. The CLI rewriting the live files between the two reads (same email, other org) files org B's login under org A's slot and overwrites A's saved login. Oracle core review #5, High (~/.cache/kiba-oracle/core-review-2026-09-24.md). Acceptance: one read of the live files yields the identity, the login bytes and the profile that are saved; put chooses the slot from that identity and writes those bytes in the same transaction; no second read; the email check in save(to:) goes with it (KibaError.mismatch stays for install); identity() callers (liveNames, StatusReader) unchanged in behaviour. No new test: tests reach KibaCore only through its public entry points and none can interleave a write between the two reads deterministically, so a test would pass before the fix too; the invariant is structural (one read) and reviewed as such. Existing save/import tests stay green. DESIGN.md: ClaudeLive/CodexLive protocol lines (~376-377, ~432-433), save step (~636-637), importLogin (~665). Files: Sources/KibaCore/Switcher.swift, ClaudeLive.swift, CodexLive.swift, DESIGN.md. Verify: swift build warning-free; ./test.sh green. Depends: none. Ownership: Switcher.swift, ClaudeLive.swift, CodexLive.swift. Claim: birch (lead, workspace .jj-ws/snapshot).
