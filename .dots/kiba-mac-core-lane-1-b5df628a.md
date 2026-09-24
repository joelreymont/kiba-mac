---
title: "Core lane 1: lock, store, secrets, live logins, status"
status: active
priority: 2
issue-type: task
created-at: "\"2026-09-24T13:20:54.120836+02:00\""
---

StoreLock, Store, Subprocess, SecretStore (KeychainItem via security tool, FileSecret, MemorySecret, ClaudeSecrets.live), ClaudeLive, CodexLive, StatusReader, and the ClaudeIdentity.fromLive fix (JSONDoc span, JSONFields shared reader, strict base64url) per DESIGN.md; also make JSONDoc.replacing throwing (badJSON/capacity, no precondition trap) and give PrivateFS.writePrivate a unique O_EXCL temp name instead of the fixed <target>.tmp, both now in DESIGN.md. Gate: swift build warning-free; a checkpoint that reads a scratch store through StatusReader. No unit tests. Depends: fs lane landed. Claim: agent=worker workspace=.jj-ws/core1.
