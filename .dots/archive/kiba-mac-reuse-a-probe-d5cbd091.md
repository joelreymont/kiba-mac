---
title: Reuse a probe that ran while kiba usage waited
status: closed
priority: 2
issue-type: task
created-at: "2026-10-29T16:39:09.245617+02:00"
closed-at: "2026-10-29T16:56:34.556078+02:00"
close-reason: implemented, swift build warning-free, swift test 73/73 green; probeAfterAnotherBeganTakesItsOutcomes fails on main
---

Problem: Sources/KibaCore/Switcher.swift probeAll always probes every saved login once it holds the turn. Each Claude Code session's Kiba mod runs 'kiba usage claude' when it hits a limit; on 2026-10-29 16:26 six or more sessions hit one together, queued on the turn and each probed all 14 accounts, and Anthropic throttled every usage check. Acceptance: probeAll notes the clock before taking the turn; once held, when every saved row's usage.fetchedAt is later than that second, it probes nothing and reports those recorded outcomes (live as liveNames decides); otherwise it probes as now. DESIGN.md Switcher section states it. Integration test: a probe waiting on the turn while another probes makes no usage request of its own; fails without the change. Files: Sources/KibaCore/Switcher.swift, DESIGN.md, Tests/KibaCoreTests/IntegrationTests.swift. Verify: swift build warning-free; swift test. Depends: none. Ownership: those files. Claim: agent=norbert workspace=.jj-ws/probe-coalesce.
