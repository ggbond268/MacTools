# Core test scope

The routine suite protects main user workflows and consequential failures. It does not try to preserve every historical regression, presentation detail, or unusual ordering of callbacks.

## Deciding what to keep

Evaluate the behavior and the consequence of a missed defect before looking at the test's label. A small UI-state test can be valuable; a unit test of a getter can add little confidence. Age and runtime alone do not decide whether to keep a test.

| Decision | Criterion |
| --- | --- |
| Keep | A core workflow or consequential boundary has no equivalent coverage. This includes permissions, data preservation, release security, and binary compatibility even in settled code. |
| Merge | Cases exercise the same behavior with the same setup and oracle. Use named table cases so failures remain diagnosable; do not combine unrelated outcomes just to lower the count. |
| Simplify | The outcome matters but its fixture, dataset, fixed delay, or repeated process startup is larger than needed. |
| Remove | A test repeats another layer's checks, locks down incidental implementation or copy, or exercises a speculative combination without significant consequences. |
| Run on demand | A critical integration check needs a real desktop, hardware, permissions, or human review. It should supplement the routine suite rather than repeat its matrix. |

These criteria apply [Google's behavior-focused testing guidance](https://testing.googleblog.com/2013/08/testing-on-toilet-test-behavior-not.html) and [guidance on testing behaviors rather than methods](https://testing.googleblog.com/2014/04/testing-on-toilet-test-behaviors-not.html). The [Practical Test Pyramid](https://martinfowler.com/articles/practical-test-pyramid.html#AvoidTestDuplication) recommends removing duplicate coverage across layers while retaining higher-level checks that add distinct confidence. These are engineering practices, not a mandated test ratio or a rule to remove every UI test.

## Running checks

```bash
make test TEST_FILTER=ActionExecutorTests
make test TEST_FILTER='ActionExecutorTests WindowSwitcherSessionTests'
make test TEST_FILTER=DiskCleanExecutorTests/testPreflightRejectsWholePlanWhenAnyItemIsLockedByRunningApp
make test
make script-tests
make ci
```

Replace the method selector with an existing method for the change. A quoted, space-separated `TEST_FILTER` runs related classes or methods in one build. `make test` regenerates the project, runs XCTest serially, and enforces per-test timeouts. `make script-tests` checks tooling, changelogs, generated plugin data, and minimum-host compatibility. `make ci` always runs both complete suites and the frozen PluginKit client compatibility check, regardless of `TEST_FILTER`.

Three Window Switcher checks require native window focus and keyboard events. They are skipped by default. Run them on an active desktop when changing those interactions:

```bash
TEST_RUNNER_MACTOOLS_RUN_DESKTOP_TESTS=1 make test TEST_FILTER='WindowSwitcherSessionTests/testFindPromotesCyclingAndPreservesNativeSearchInput WindowSwitcherLifecycleTests/testRecentUseSearchStartsAtNextWindowAndFailureDoesNotReopen WindowSwitcherLifecycleTests/testModifierReleaseAfterEnteringSearchDoesNotCommit'
```

## What stays

| Area | Core outcomes |
| --- | --- |
| Host and actions | Startup routing, action dispatch, provider availability, confirmation, cancellation, and shortcut conflicts. |
| Plugins and CLI | Validated installation/update/removal, trust, compatibility, protocol validation, and rollback without losing existing data. |
| Automation | Ordered workflow execution, stop/continue behavior, cancellation, recursion prevention, and sensitive-data filtering. |
| Preferences | Persistence, backup round trips, failed-import recovery, and cloud conflicts that must not overwrite local edits. |
| Clipboard | Capture and exclusions, copy/paste and queue order, saved snippets, encrypted storage, backup restore, and failed-write recovery. |
| Disk cleanup | Scan/select/execute, allowlists, reserved paths, symlink and identity checks, confirmation, cancellation, and staging recovery. |
| System plugins | The main action, permission denial, service shutdown, and hardware failure/fallback through injected services. |
| Input and windows | Recognition or matching, action execution, cancellation, focus/target validation, and stored mappings. |

Disk removal and private-data handling intentionally retain more boundary coverage than presentation code. A rare failure still warrants a test when it could delete the wrong files, expose private data, or leave input/hardware in an unsafe state.

## Low-value coverage removed

- Automated window rendering, screenshot comparisons, colors, spacing, font metrics, focus/drag event pumping, and native accessibility view traversal.
- Fixed copy, symbol/catalog inventories, straightforward getters, and already-covered forwarding or formatting checks.
- Repeated combinations of old migrations, stale callbacks, device identities, and tiny timing variations when the main behavior already has coverage.
- Large synthetic performance cases and process fan-out used to test settled implementation details.
- The standalone panel drag and palette-capture fixtures, unused process-probe build targets, and the script tests that repeatedly compile and launch UI/E2E helpers.
- Documentation/workflow source-string assertions that enforce incidental wording or script layout rather than behavior. Executable package, release, changelog, licensing, and minimum-host validation stays.

Review rendering, mouse/keyboard integration, real hardware, and performance when affected. The opt-in [actions and automation E2E tools](actions-automation-e2e.md) remain available for real shortcut, permission, and cross-surface evidence; they are outside `make test` and `make ci`. Use a representative scenario and record the result; do not rebuild a large automated UI matrix.

## Examples from this review

| Decision | Reason |
| --- | --- |
| Keep PluginKit stored-property layout checks | These check binary ABI compatibility, not visual layout; failure can break installed plugins. |
| Keep action confirmation, cleanup preflight, and backup recovery checks | They protect permissions and user data even when the failure is uncommon. |
| Remove duplicate host widget measurement and cache-call matrices | Coordinator and host suites repeated implementation and rendering details; routing, lifecycle, catalog validation, and persistence remain covered. |
| Merge translator endpoint/configuration cases | The same normalization and validation behaviors are checked with named inputs and typed errors; fixed localized messages and defaults are omitted. |
| Remove provider-document/source-string inventory assertions | Runtime manifest consistency is tested directly; matching class names in another test or script does not prove behavior. |
| Keep release-gate and signing tests | Some inspect workflow configuration, but the assertions protect publication and credential boundaries rather than incidental wording. |

## September 2026 reduction

The initial reviewed baseline contained 417 XCTest files and 5,562 test method declarations. Before integrating subsequent upstream changes, the initial reduction removed 114 test files and pruned mixed suites method by method, retaining 2,332 cases alongside 221 script tests and the frozen PluginKit binary compatibility client. Representative changes from that pass:

| Area | Before | Retained after pruning |
| --- | ---: | ---: |
| App | 656 | 133 |
| Core | 951 | 540 |
| Clipboard | 763 | 228 |
| Trackpad gestures | 333 | 54 |
| Window switcher | 344 | 120 |
| Automatic input switching | 115 | 17 |
| Device battery | 157 | 38 |
| Disk cleanup | 465 | 297 |

These are method declarations, not XCTest runtime counts. Independently edited tests in the working tree are preserved and may change the totals. There is no comparable full-suite baseline result available, so this reduction does not claim a measured speedup percentage.

Native keyboard interaction checks are excluded from routine runs; the three critical Window Switcher checks described above remain available on demand. Clipboard page updates now use one page plus one item instead of a 50,000-item timing fixture; assertions cover recency, selection, and metadata-only reads. Command runner checks combine argument validation with result parsing and keep representative timeout/cancellation cases. Notes persistence uses one save/reload/delete flow instead of separate default/getter checks. Prefer completion signals or observable outcomes over fixed sleeps when the test can use them.
