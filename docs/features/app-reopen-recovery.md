# Feature — App Reopen Recovery

Last verified: 2026-08-13

Status: implemented — Draft/WIP, not mergeable
Source of truth: yes

## Summary

- The AppKit reopen callback presents Settings.
- One named local IPC port elects the running instance.
- Secondary copy → `show-settings` command → acknowledged termination before bootstrap.
- Up to 32 valid URLs within one aggregate 16 MiB envelope are queued before ownership resolution, then routed by the primary runtime or forwarded within the shared launch budget.

## User flow

- MacTools is already running without a visible window, or with an existing window.
- The user launches the app again from Finder, Spotlight, or the Dock.
- The MacTools Settings window is shown and activated.
- If a launcher starts another copy, it sends the request and terminates.
- Only one runtime remains active.

## Business rules

| Rule | Markdown | Central code | Consumption |
|---|---|---|---|
| No durable business rule | — | — | — |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-12 | Reopen → Settings | Recovery independent of the menu-bar icon | The AppKit callback remains in place |
| 2026-08-12 | Single instance + acknowledged IPC | Avoid competing runtimes | The secondary copy sends the request and terminates before bootstrap |

## Plan

- [x] P001 — Define the recovery scenario.
- [x] P002 — Handle AppKit reopen.
- [x] P003 — Add tests, changelog, and Draft PR.
- [x] P004 — Reproduce the launcher case with two processes.
- [x] P005 — Diagnose the risk and write the architecture plan.
- [x] P006 — Replace polling with single-instance coordination and IPC.
- [ ] P007 — Certify with multi-process tests and full QA.
- [x] P008 — Preserve deep links during cold launch and secondary forwarding.

## TODO

- [x] F001 — Define the recovery surface — files: `docs/features/app-reopen-recovery.md` — status: done
- [x] F002 — Show Settings on reopen — files: `Sources/App/MacToolsApp.swift` — status: done
- [x] F003 — Cover the AppKit callback — files: `Tests/App/MacToolsAppDelegateTests.swift` — status: done
- [x] F004 — Guarantee one runtime — files: `Sources/App/AppInstanceCoordinator.swift`, `Sources/App/MacToolsAppRuntime.swift` — status: done
- [x] F005 — Cover protocol, ACK, invalidation, concurrency, crash, and timeout boundaries — files: `Tests/App/AppInstanceCoordinatorTests.swift`, `Tests/App/AppInstanceCoordinatorProcessTests.swift`, `Tests/Support/AppInstanceProbe/AppInstanceProbe.swift` — status: done

## Codex implementation journal

- 2026-08-12 — `MacToolsAppDelegate.applicationShouldHandleReopen` delegates to `AppWindowRouter.showSettings()` with either visibility state and returns `false` because the app handles the AppKit event itself. `MacToolsAppDelegateTests` covers this wiring; `AppWindowRouterTests` covers activation, deminiaturization, and ordering front.
- 2026-08-12 — In Debug, the instance scans running applications once per second; launching another copy with the same bundle ID opens Settings in the existing instance once per PID. Bundle ID and PID filtering tests were added.
- 2026-08-12 — Real validation: `make run` launches the repository bundle, then opening a competing Xcode copy presents Settings in the existing instance. The capture was visually checked.
- 2026-08-12 — Diagnostic correction: QA shows that two processes remain active. Polling is symmetric; it guarantees neither which instance presents Settings nor runtime uniqueness.
- 2026-08-12 — Replacement plan: `docs/superpowers/plans/2026-08-12-single-instance-reopen-recovery.md`. The PR remains Draft; it must not become Ready before multi-process evidence exists.
- 2026-08-12 — Replaced Debug polling with `AppInstanceCoordinator`, a named `CFMessagePort` protocol, bounded forwarding, and owner-only runtime construction. `MacToolsAppRuntime` now owns `PluginHost`, the status item, URL routing, updater, and lifecycle cleanup only after primary election.
- 2026-08-12 — Verification: focused coordinator, delegate, and window-router tests passed; Debug and Release builds passed. Real QA used `open -n` on the Debug bundle: the secondary process terminated, one PID remained, and the existing Settings window was frontmost.
- 2026-08-12 — Full suite: the instance-coordination change no longer terminates parallel XCTest hosts. The suite still fails in three existing `DiskCleanPluginTests` cases (`testCleanActionTitleReportsSelectionAndRemovalMode`, `testConfirmingPhaseReplacesCleanActionWithConfirmAndCancel`, and `testTrashCompletionSubtitleDoesNotClaimSpaceWasReclaimed`); direct rerun confirms they are outside this change.
- 2026-08-12 — Review fixes: retries now reuse one request ID, per-attempt IPC timeouts are capped by the global deadline, and a process promoted after an invalid owner port presents Settings after its runtime starts. Multi-process certification and non-blocking launch coordination remain open Draft gates.
- 2026-08-12 — Review fixes: secondary IPC forwarding now runs off the MainActor; its send and reply budgets share the remaining global deadline. Idempotence records expire after 30 seconds, and the coordinator logs command receipt, response, duplicate acknowledgement, and secondary termination. Multi-process certification remains an open Draft gate.
- 2026-08-13 — Final review fixes: the coordinator is actor-confined, its lifecycle task is owned and cancellation-aware, the CFMessagePort transport is injectable, and invalid protocol messages produce warnings. A dedicated probe validates ten concurrent processes with nine acknowledged commands, crash promotion, an unresponsive owner under two seconds, and independent namespaces. The 1.5-second IPC budget leaves process-launch and termination margin inside the 2-second user-visible target. AppKit reopen and IPC handler convergence is covered directly.
- 2026-08-13 — Test integration: `project.yml` and the plugin project generator register the process probe as a test dependency without including probe sources in `MacToolsTests`.
- 2026-08-13 — Review fix: incoming URLs are retained until primary runtime creation. A secondary instance forwards queued URLs through the existing IPC channel before termination; the primary retries until its runtime can route them. Unit tests cover queueing and forwarding.
- 2026-08-13 — Follow-up review: the primary now ACKs validated URLs into its bounded pre-runtime queue, including Right Click compatibility URLs larger than 1 MiB within a 16 MiB IPC safety limit. One stable IPC command and one launch-wide deadline with a 0.5-second URL reserve prevent action replay and unbounded secondary lifetime. No manifest or inventory changed.

## Current files

| Area | Files |
|---|---|
| App lifecycle | `Sources/App/MacToolsApp.swift` |
| Instance coordination | `Sources/App/AppInstanceCoordinator.swift` |
| Owner runtime | `Sources/App/MacToolsAppRuntime.swift` |
| Architecture plan | `docs/superpowers/plans/2026-08-12-single-instance-reopen-recovery.md` |
| Settings presentation | `Sources/App/AppWindowRouter.swift` |
| Tests | `Tests/App/AppInstanceCoordinatorTests.swift`, `Tests/App/MacToolsAppDelegateTests.swift` |
| Test integration | `project.yml`, `scripts/plugins/generate-plugin-project-config.rb` |

## Tests / QA

The September 2026 test reduction retired the native UI checks and process fan-out probe. The completion records below describe the original implementation validation; current automated checks cover the core coordinator behavior. Repeat real launch and window activation checks manually when those paths change.

- [x] The AppKit callback requests Settings; the router activates, deminiaturizes, and orders the window front.
- [x] Run `MacToolsAppDelegateTests` and `AppWindowRouterTests` after implementation.
- [x] `open -n` on the Debug bundle leaves one PID and presents Settings in the primary instance.
- [x] Unit coverage verifies ACK forwarding and primary-port invalidation/recovery.
- [x] Process coverage verifies ten concurrent launches, primary crash, an unresponsive primary, and independent namespaces.
- [ ] Repeat Finder, Spotlight, Dock, and launcher QA with one final process.

## History

<!-- Read only for a bug, regression, audit, or explicit request. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-12 | `vwt` | Feature | MacTools reopen as a recovery path |
