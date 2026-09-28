---
title: "Restore the live item only on the login's evidence"
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-28T10:28:32.713323+02:00\\\"\""
closed-at: "2026-09-28T10:51:23.643853+02:00"
close-reason: "landed as the commit under main: restore only on the login's evidence (completed and filed nothing), root kept on a failed restore, adding.service recorded, unrestored exclusion, isMixed checks pending before decoding, broken login config counts as no evidence; build warning-free, 67 tests green at the integrated tip"
---

Problem: Sources/KibaCore/LoginRunner.swift settle/recover/restore/filed infer that the add's Claude login overwrote the live Keychain item whenever the item changed and the login filed no credentials in its own home. Oracle core review 2026-09-28 (~/.cache/kiba-oracle/core-review-2026-09-28.md), High 1-4 and the Medium: (1) a failed or cancelled add during which Claude Code refreshed the live token writes the stale snapshot back over the refresh; (2) recover() calls filed(root:before:nil), so a loginService item left by an earlier failed import counts as this add's output, and settle's removing(root) deletes the root's evidence when restore throws; (3) a failed restore leaves the adding record but add's deferred ops.leave() releases the turn, so use/save/probeAll/redeem run and a later recover restores the old bytes over a completed switch; (4) the adding row stores only bytes, so a launch with another CLAUDE_CONFIG_DIR restores them into the wrong service. Medium: ClaudeLive.isMixed decodes the live identity (ClaudeIdentity.profile) before checking pending, so a live config without oauthAccount (e.g. {} after a failed install put the previous config back beside new credentials) throws badJSON instead of reporting the pending install, and use cannot repair it.

Design (the contract):
1. The login wrote the live item only when it COMPLETED and FILED NOTHING of its own. Completed = its home config paths.claudeConfigFile(root:) exists and holds a top-level oauthAccount object (JSONDoc.objectSpan(ClaudeIdentity.Key.account) != nil; a config that is not valid JSON throws, nothing is swallowed). Filed = root/.claude/.credentials.json exists or paths.loginService's item holds bytes. Only completed && !filed writes live bytes that differ from the snapshot back (the item removed when the snapshot was nil) and returns them as `written` for import (step 6c). In every other case the live item stays whatever it holds: a change is Claude Code's own refresh.
2. prepare (Claude) removes any leftover item under paths.loginService before the launch (SecretStore.remove(), a no-op when absent), so filed() needs no `before` and any bytes found afterwards are this login's. Drop Snapshot.before; the snapshot is the LiveItem alone.
3. LiveItem gains `service: String` (paths.keychainService at the snapshot). Table adding gains `service TEXT NOT NULL`. restore and recover address keychain.item(old.service), never the current paths.keychainService. Migration in Store.init, following the ownerColumn/addOwner pattern: when pragma_table_info('adding') lacks `service`, ALTER TABLE adding ADD COLUMN service TEXT NOT NULL DEFAULT '' then UPDATE adding SET service = <paths.keychainService> (an older build always addressed the launch's live service, so that is what its record meant).
4. The root survives a failed restore. In add, settle is not wrapped in removing(root). Inside settle: filed, the completion check and restore run first (a throw leaves root and the adding record for recover); then check(ended), the loginProducedNothing throw and the return run inside removing(root). Codex (nil snapshot) keeps its behaviour.
5. recover(): stop(root); restore(old, wrote: filed(root) == nil && completed(root)); removeTree(root). A missing root is not completed.
6. Exclusion: while store.adding(p) holds a record, Switcher.saveLive and Switcher.liveNames throw a new KibaError.unrestored(Provider), reason one line in the style of unrepaired, e.g. "the live <Provider> login waits to be put back after an add; a new <Provider> add or an app start does it". So save, use, probeAll (saveBackError and providerError, no account probed), and redeem refuse until LoginRunner.init or a Claude add runs recover. LoginRunner.add's importInTurn/probeInTurn never call those, so an add in flight is unaffected. StatusReader reads no markers.
7. ClaudeLive.isMixed: read the raw live pair first (live(), so orphanLive still comes first), then pending (true when set), then decode the identity only for the mixed comparison with the installed row. Split login() so the decode is a step both use.
8. DESIGN.md: rewrite the affected text in "Add account (LoginRunner)" (the init paragraph, steps 3, 5, 6b, 7's leftover note, the closing paragraph on the live login), "Switcher" (the new refusal beside unrepaired), "Errors" (the new case), "Claude live login" (isMixed's order), and any schema text for adding. Keep the old-CLI rationale; state the residual: a legacy CLI killed between writing tokens and its config leaves no evidence and its write stays.

Acceptance (Tests/KibaCoreTests/IntegrationTests.swift, integration only, through LoginRunner/Switcher/Store; no per-type tests):
- failedLoginPutsLiveItemBack and cancelledAddStopsLoginAndPutsLiveItemBack invert: a live change beside a login that did not complete stays; rename them to say so.
- A legacy login that completes (writes the live item and its home config, exits 0): the live item goes back to the snapshot and the written bytes are imported as the new account. Add this case if addClaudeFromFileAndFromKeychain lacks it.
- startUndoesAddTheAppDidNotFinish: the restore happens only with the home config present in the root; without it the live item stays; a leftover loginService item from an earlier add does not count as the login's output when the login completed by writing the live item (High 2).
- Recovery addresses the recorded service: noteAdding with a service other than paths.keychainService; recover writes there and leaves the current live item alone (High 4).
- With an adding record present and no runner constructed: save, use, probeAll (report: unrestored in both error fields, no accounts), redeem refuse with unrestored; constructing the runner clears it and use then works (High 3).
- The previous-schema fixture (~line 1444) migrates: an existing adding row gets the launch's service; noteAdding/adding round-trip the service.
- isMixed repair: live config {}, live creds, pending set for saved C: use(.claude, C) succeeds and the live files hold C (Medium).
- Update addUndoesTheAddBeforeIt and addClaudeOverLeftoverKeychainItem for the removed `before` and the completion rule as needed.
- No stubs, TODOs, dead code, magic numbers; short names; every error a KibaError.

Files: Sources/KibaCore/LoginRunner.swift, Sources/KibaCore/Store.swift, Sources/KibaCore/Switcher.swift, Sources/KibaCore/ClaudeLive.swift, Sources/KibaCore/KibaError.swift, DESIGN.md (sections named above), Tests/KibaCoreTests/IntegrationTests.swift.
Verify: export TMPDIR=$(mktemp -d /private/tmp/kiba-XXXXXX); swift build 2>&1 | grep -E 'warning|error|Build complete' (warning-free); ./test.sh (all green).
Depends: none.
Ownership: the files above, inside .jj-ws/<id> only. One commit, subject "Restore the live item only on the login's evidence".
Claim: agent=worker-core workspace=.jj-ws/kiba-mac-restore-the-live-36b23adb
