---
title: README
status: open
priority: 2
issue-type: task
created-at: "2026-09-24T12:47:51.489075+02:00"
blocks:
  - kiba-mac-panelview-visual-design-5d3016c7
  - kiba-mac-loginrunner-add-account-8c8a8f3e
---

Problem: no user documentation. Acceptance: README.md in the voice of ~/Work/kiba/README.md: why, requirements (macOS 14+, claude and codex CLIs), install (./build.sh), first run (Save the current login), adding accounts (Terminal login, browser reminder, never log out), how switching works on macOS (Keychain item, .claude.json splice, Codex auth.json, save-back, marker, mixed), usage per account, the panel (row colours, ordering, figures, keyboard), store location, build and test, license. No claims the code does not make. Files: README.md. Verify: every command in it runs. Depends: PanelView, LoginRunner dots. Ownership: README.md. Claim: unassigned. Contract: DESIGN.md is the interface spec; implement exactly the named section. Rules: AGENTS.md. Tests live in Tests/KibaCoreTests, run in a scratch env, never touch real credentials. No stubs, no TODOs, short names.
