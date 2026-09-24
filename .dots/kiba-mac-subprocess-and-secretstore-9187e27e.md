---
title: Subprocess and SecretStore with Keychain via security tool
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.354933+02:00"
blocks:
  - kiba-mac-privatefs-and-jsondoc-a315fc2e
  - kiba-mac-provider-paths-slotname-21508c16
---

Problem: no way to read or write the live Claude tokens without Keychain prompts. Acceptance: DESIGN.md 'SecretStore' and 'Subprocess' exactly: posix_spawn runner with pipes, concurrent drain, env override, POSIX_SPAWN_SETSID, PATH lookup; FileSecret, MemorySecret, KeychainItem (find -w read, exit 44 -> nil; add -U with -w last and the secret piped on stdin twice under setsid; delete, 44 -> no-op), ClaudeSecrets.live chosen by file existence. Tests: Subprocess echo/exit status/stdin round trip/setsid (child has no controlling tty: /dev/tty open fails inside it); KeychainItem round trip on service 'kiba-mac-test-<uuid>' with a secret containing quotes, braces, and non-ASCII, removed in defer, read of a missing item is nil; FileSecret 0600. If the harness denies the Keychain test, STOP and report with the exact command. Files: Sources/KibaCore/Subprocess.swift, SecretStore.swift, Tests/KibaCoreTests/SubprocessTests.swift, SecretStoreTests.swift. Verify: swift test. Depends: PrivateFS, Paths dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
