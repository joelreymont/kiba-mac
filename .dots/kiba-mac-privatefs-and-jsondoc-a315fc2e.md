---
title: PrivateFS and JSONDoc byte splicing
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.286626+02:00"
---

Problem: no atomic private writes or byte-exact JSON splicing. Acceptance: DESIGN.md 'PrivateFS' and 'JSONDoc' exactly: 0600 temp+rename in the same dir, symlink chain <=8 hops followed, temp removed on failure, 0700 recursive dirs, removeTree; JSONDoc locates top-level and nested value spans with correct string/escape/nesting handling, closingBrace with hasMembers, replacing; 4 MiB cap -> capacity. KibaError already exists in the base (Sources/KibaCore/KibaError.swift); throw its cases. Tests: mode bits checked via stat, symlinked live file keeps the link and replaces the target, failure leaves no .tmp, spans on adversarial docs (escaped quotes, braces inside strings, nested objects, unicode). Files: Sources/KibaCore/PrivateFS.swift, JSONDoc.swift, Tests/KibaCoreTests/PrivateFSTests.swift, JSONDocTests.swift. Verify: swift test. Depends: none. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
