---
title: Package skeleton, app stub, build and test scripts
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.273218+02:00"
---

Problem: the base has a bare Package.swift and an empty app main; there is no bundle or test script. Acceptance: keep Package.swift as is unless a bundle need forces a change; KibaApp main.swift creates an NSStatusItem with a temporary text title 'kiba' that toggles an empty NSPopover (LSUIElement via Info.plist in build.sh); build.sh assembles build/Kiba.app per DESIGN.md 'Build, bundle, test' (Info.plist, ad-hoc codesign, install to ~/Applications by rename) without the icon step (icon dot adds it); test.sh exports the scratch env and runs swift test; both scripts export TMPDIR to a fresh directory made with an explicit mktemp template under /private/tmp (this machine inherits a TMPDIR that does not exist, which makes swiftc fail with couldNotFindTmpDir); one smoke test in KibaCoreTests. Files: Sources/KibaApp/main.swift, build.sh, test.sh. Verify: swift build, swift test, ./build.sh produces build/Kiba.app and it launches with a menu bar item and no Dock icon. Depends: none. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
