---
title: PrivateFS and JSONDoc byte splicing
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-24T12:47:51.286626+02:00\\\"\""
closed-at: "2026-09-24T13:32:09.149914+02:00"
close-reason: implemented, destruction-reviewed by the lane, landed as roynxysqukrt; build and tests green at tip
---

Problem: no atomic private writes or byte-exact JSON splicing. Acceptance: DESIGN.md 'PrivateFS' and 'JSONDoc' exactly: 0600 temp+rename in the same dir, symlink chain <=8 hops followed, temp removed on failure, 0700 recursive dirs, removeTree; JSONDoc locates top-level and nested value spans with correct string/escape/nesting handling, closingBrace with hasMembers, replacing; 4 MiB cap -> capacity. KibaError already exists in the base (Sources/KibaCore/KibaError.swift); throw its cases. Files: Sources/KibaCore/PrivateFS.swift, JSONDoc.swift, Tests/KibaCoreTests/PrivateFSTests.swift, JSONDocTests.swift. Verify: swift build warning-free; a checkpoint through the real entry point on a scratch store. Depends: none. Ownership: listed files. Claim: agent=worker workspace=.jj-ws/fs. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Integration tests only (AGENTS.md); write no unit tests in this dot. No stubs, no TODOs, short names.
