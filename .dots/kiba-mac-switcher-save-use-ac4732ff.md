---
title: "Switcher: save, use, forget, probeAll, importLogin"
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.411353+02:00"
blocks:
  - kiba-mac-claudelive-identity-save-c8a5f52f
  - kiba-mac-codexlive-identity-save-c0d7efff
  - kiba-mac-claudeprobe-usage-and-6a22f306
  - kiba-mac-codexprobe-usage-refresh-206b852b
---

Problem: no command orchestration. Acceptance: DESIGN.md 'Switcher' exactly: save refuses on interrupted/mixed, returns nil without live; use does save-back (skip on installing, skip on mixed, save when live) then install then probes the installed account as live and writes usage; forget removes the slot (noAccount when absent); probeAll saves back (error captured), scans, probes each unlocked with live flag, writes usage or removes a revoked non-live slot, never removes the live one; importLogin reads from the throwaway root. Tests through the real entry points with FileSecret/StubHTTP: token rotation survives a switch (live tokens saved back before install), interrupted marker skips save-back, revoked slot removed, live revoked kept. Files: Sources/KibaCore/Switcher.swift, Tests/KibaCoreTests/SwitcherTests.swift. Verify: swift test. Depends: ClaudeLive, CodexLive, ClaudeProbe, CodexProbe dots. Ownership: listed files. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
