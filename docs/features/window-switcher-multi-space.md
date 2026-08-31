# Feature — Window Switcher multi-Space window discovery

Last verified: 2026-08-31

Status: ready-for-publish
Source of truth: yes

## Summary

- Window Switcher must list eligible windows located on every macOS Space, not only the active Space.
- Existing application ordering, per-window shortcut assignment semantics, accessibility permission handling, and AX-based activation remain unchanged when their data is available.
- The correction is limited to cached discovery and activation fallback for windows that are not exposed by the active Space's Accessibility window list.
- CoreGraphics discovery runs off the main actor; each session awaits the current snapshot before AX enrichment.
- Missing CoreGraphics titles use unique geometry matching only when the AX candidate is unambiguous; CG-backed and AX-only entry IDs use disjoint namespaces.
- Duplicate title-and-geometry metadata never relies on enumeration order; a sole on-screen CoreGraphics record may receive the sole AX candidate, otherwise entries remain CG-only.
- Exact title-and-geometry matches are resolved before titleless geometry fallbacks; when AX exposes more indistinguishable candidates than CoreGraphics, only the cardinality surplus is retained as AX-only entries.
- Post-activation AX fallback lookup uses the same cancellation and bounded deadline and focuses from the current AX minimized state.
- Direct-cycle presses received while the initial catalog scan is pending are accumulated and applied before the overlay is shown.

## User flow

1. The user opens Finder windows A, B, and C across two Spaces.
2. The user invokes Window Switcher from either Space.
3. The switcher shows all three Finder windows, including windows on the inactive Space.
4. Selecting a window activates its application and uses its Accessibility element for precise focus when macOS exposes that element.

## Acceptance criteria

- [x] A window belonging to an inactive Space is present in the Window Switcher catalog.
- [x] Windows from the active and inactive Spaces remain distinct entries when they belong to the same application.
- [ ] Selecting an entry still restores an unminimized AX window and raises/focuses it when an AX element is available.
- [x] Applications without a discoverable window keep the existing application-level fallback entry.
- [x] Missing required window-list identity, process, geometry, layer, or alpha metadata fails closed; optional title or on-screen metadata may use safe fallbacks without crashing the plugin.

## Definition of done

- [x] The catalog discovers all-space windows through a public macOS API and merges them with existing AX snapshots.
- [x] A focused regression test covers an off-active-Space window record and duplicate same-application windows.
- [x] Targeted tests, plugin build, repository PR checks, whitespace checks, and the separate standards/spec/security reviews pass.
- [x] Manual macOS acceptance is recorded, including any unavailable interaction evidence.
- [x] README and the unreleased changelog describe the corrected user-visible behavior.
- [ ] The change is published as one focused pull request closing issue #357.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| Eligible windows from inactive Spaces are included | This file | `WindowSwitcherAppCatalog` and its window-record parser | Window Switcher catalog, key-selection panel, direct-cycle mode |
| AX metadata and activation remain preferred when available | This file | `WindowSwitcherAppCatalog` | Window Switcher activation |
| A missing AX element does not remove a discoverable window | This file | `WindowSwitcherAppCatalog` and `WindowSwitcherAppEntry` | Window Switcher catalog and shortcut assignment |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-31 | Refresh the `CGWindowListCopyWindowInfo` all-window snapshot off the main actor and await the current refresh before building a session | The issue requires cross-Space discovery without adding a synchronous global scan to the shortcut-opening path | Catalog refreshes stay responsive and each new session uses a fresh system snapshot |
| 2026-08-31 | Keep AX elements optional for records discovered only by CoreGraphics | macOS may not expose an inactive-Space window through Accessibility until its application is activated | The app is activated with the existing safe fallback; exact AX focus remains used whenever available |
| 2026-08-31 | Correlate AX and CoreGraphics records only through public title, position, and size attributes | The Accessibility SDK does not expose a documented window-number attribute | The system window number is retained for entry identity; exact post-activation focus remains best-effort when metadata matches |
| 2026-08-31 | Use the system window number in window-entry and shortcut-binding identities when available; migrate a legacy application binding only when exactly one current window proves the target, otherwise keep legacy ordinal and application bindings unresolved until explicit reassignment | Array indexes change as Spaces and window order change, and persisted ordinal data cannot prove which current window it represented | Stable entries cannot retarget an old shortcut; the sole provable legacy target keeps its manual binding, while ambiguous legacy bindings remain stored but are not silently assigned |
| 2026-08-31 | Restrict CoreGraphics-only records to regular-app, layer-zero, positive-alpha, minimum-sized windows | CoreGraphics does not provide the Accessibility role/subrole used by the existing AX filter | Inactive-Space records remain discoverable without adding system or menu-bar surfaces |
| 2026-08-31 | Do not silently cap eligible CoreGraphics or Accessibility windows | A hidden cap would violate the all-eligible-window contract and drop valid same-application windows | All valid records are retained; each catalog session shares one cancellation-aware AX time budget |
| 2026-08-31 | Use unique geometry matching only for an unambiguous missing-title candidate | `kCGWindowName` is optional and exact title matching can duplicate an active window | AX metadata is preferred without guessing between same-geometry windows |
| 2026-08-31 | Give CG-backed and AX-only entries disjoint IDs | A numeric window number can equal an AX-only array index | SwiftUI selection and entry lookup remain unambiguous |
| 2026-08-31 | Bound post-activation AX fallback and use its current minimized state | A slow AX server or stale CG state must not freeze activation or prevent deminimization | The app activation fallback remains safe and bounded while current AX state is honored |
| 2026-08-31 | Reject ambiguous AX matches and use `isOnScreen` only when it identifies one record among otherwise identical CoreGraphics candidates | `optionAll` order is not a stable identity across Spaces | An ambiguous window stays safely CG-only instead of receiving the wrong AX element |
| 2026-08-31 | Accumulate direct-cycle deltas while the initial session is preparing | All-Space discovery is asynchronous and later key presses must not disappear | Repeated presses preserve their requested movement before the overlay is displayed |
| 2026-08-31 | Treat a new press after a pending release as a new direct-cycle gesture | A slow all-Space snapshot must not auto-commit a gesture that the user already released | The pending release is cleared and the new press controls whether the prepared overlay remains visible |
| 2026-08-31 | Reconcile Accessibility revocation at the event-tap boundary | Permission can disappear between the last plugin refresh and a global input event | The tap stops consuming shortcut state and notifies the plugin to cancel the active session |
| 2026-08-31 | Resolve exact AX/CG metadata matches before titleless geometry fallbacks and preserve only cardinality-surplus AX candidates | Optional titles and duplicate bounds cannot provide a stable cross-API identity | A titleless record cannot steal an exact match, and extra AX windows remain switchable without duplicating every ambiguous candidate |
| 2026-08-31 | Inject application activation, post-activation lookup, and focus callbacks at the catalog boundary | CG-only activation is platform-dependent and cannot be exercised safely with live applications in unit tests | The fallback contract is testable without launching or focusing a real user application |
| 2026-08-31 | Require a completed CoreGraphics refresh before CG-only activation and allow AX-backed entries to tolerate geometry drift | Cached records must not authorize a stale window, while AX already provides the stronger activation handle | Timeout or saturation fails closed for CG-only activation; valid AX-backed focus is not rejected solely because the window moved |
| 2026-08-31 | Invalidate late refreshes by generation, permit a bounded replacement, and cap record lookup by PID before AX enrichment | A cancelled synchronous provider cannot be interrupted, but a timed-out provider must not permanently block recovery or accumulate without bound | Catalog sessions remain responsive, stale results cannot overwrite newer snapshots, and the all-eligible-window contract is preserved |
| 2026-08-31 | Treat an unavailable application launch date as an optional identity value, while requiring matching PID, termination state, bundle identity, and any dates exposed by both snapshots | `NSRunningApplication.launchDate` is optional for legitimate running applications | Missing dates do not block normal activation; an observed launch-date mismatch still rejects a reused process |

## Plan

- [x] P001 — Revalidate issue #357, the canonical repository, concurrent PRs, and GitButler state.
- [x] P002 — Define the all-Space discovery, AX enrichment, fallback activation, and regression-test contract.
- [x] P003 — Implement the catalog change and focused tests.
- [x] P004 — Update README/changelog and complete targeted plus PR verification.
- [ ] P005 — Publish one focused PR and confirm it remotely.

## TODO

- [x] F001 — Add an injectable all-window CoreGraphics record provider and safe parser — files: `Plugins/WindowSwitcher/Sources/WindowSwitcherAppCatalog.swift` — status: done
- [x] F002 — Merge CoreGraphics records with AX snapshots and preserve activation fallbacks — files: `Plugins/WindowSwitcher/Sources/WindowSwitcherAppCatalog.swift`, `Plugins/WindowSwitcher/Sources/WindowSwitcherModels.swift` — status: done
- [x] F003 — Add regression coverage for inactive-Space and same-application windows — files: `Plugins/WindowSwitcher/Tests/WindowSwitcherPluginTests.swift` — status: done
- [x] F004 — Document the corrected behavior — files: `README.md`, `changes/unreleased/window-switcher-multi-space.md` — status: done

## Journal impl Codex

- 2026-08-31 — Plan created from issue #357. The scoped seam is the existing Window Switcher catalog; no manifest, PluginKit, dependency, or version change is planned.
- 2026-08-31 — Added `WindowSwitcherWindowRecord.parse` and an injected `.optionAll` CoreGraphics provider. Records are filtered to minimum-sized layer-zero windows, retain offscreen status, and are deduplicated by system window number; the provider runs off the main actor and each session awaits its current refresh.
- 2026-08-31 — `WindowSwitcherAppCatalog` now merges all-space records with AX snapshots through public title/position/size metadata, keeps AX focus/raise behavior, and falls back to `.activateAllWindows` plus a post-activation AX lookup for a CoreGraphics-only window.
- 2026-08-31 — Added focused parser/model regression tests and updated README plus the plugin changelog. The focused tests and `make build-plugin PLUGIN=WindowSwitcher` passed; unrelated compile warnings remain outside this change and will be attributed in the PR gate record.
- 2026-08-31 — `make ci` passed all 195 script tests and changelog validation, but the repository XCTest phase reported six failures outside WindowSwitcher (`DiskCleanPluginTests` x3, `AppleShortcutsCommandRunnerTests` x2, and `PluginPackageManifestTests` x1). The standalone PluginKit v5 compatibility check passed.
- 2026-08-31 — Manual system inspection created Finder windows on two existing Spaces: the real CoreGraphics inventory returned 6 Finder windows with `.optionAll` and 2 with `.optionOnScreenOnly`. `make run` could not install the Debug app because the existing installer rejected the signed-but-missing `MacToolsTests.xctest`; launching the built app directly exposed no accessible Window Switcher overlay, so end-to-end visual selection remains unverified.
- 2026-08-31 — Standards/spec review required explicit bounded-snapshot rationale, strict numeric metadata parsing, AX/CG merge coverage, and an accurate shortcut-identity limitation. The implementation and tests now include those constraints; exact visual selection of a CG-only inactive-Space window remains platform/session dependent.
- 2026-08-31 — Follow-up spec review found optional CoreGraphics titles could duplicate AX windows and mixed CG/AX-only IDs could collide. The merge now uses unique geometry matching only when a title is missing, entry IDs use disjoint namespaces, and final entry/application fallback conversion is covered by tests.
- 2026-08-31 — Final targeted verification passed 33 Window Switcher tests, `make build-plugin PLUGIN=WindowSwitcher`, `make script-tests` (195 tests), and the standalone PluginKit v5 compatibility check. The global XCTest phase still has five unrelated failures; the exact list is recorded in the final PR gate.
- 2026-08-31 — The latest `make ci` XCTest phase failed only outside Window Switcher: `DiskCleanPluginTests.testCleanActionTitleReportsSelectionAndRemovalMode`, `DiskCleanPluginTests.testConfirmingPhaseReplacesCleanActionWithConfirmAndCancel`, `DiskCleanPluginTests.testTrashCompletionSubtitleDoesNotClaimSpaceWasReclaimed`, `PluginPackageManifestTests.testRichProjectedManifestDecodesProductMetadata`, and `DeviceBatteryCommandRunnerTests.testFiltersOutputWhileDrainingPipe`. The Window Switcher class remained green.
- 2026-08-31 — Final review follow-up identified ambiguous AX/CG correlation and dropped direct-cycle presses during asynchronous preparation. The merge now requires an unambiguous candidate (or one sole on-screen record), post-activation lookup rejects multiple matches, and preparation accumulates cycle deltas; focused regressions cover reversed record order and a controlled slow provider.
- 2026-08-31 — Security follow-up identified a permission race on direct-cycle key-up. Release now refreshes Accessibility permission before activation and cancels when it is no longer granted; the focused suite covers this race with a controlled permission harness.
- 2026-08-31 — Replaced external-application-dependent direct-cycle regressions with a suspendable injected entry provider. Queueing and permission-revocation tests now run deterministically without `XCTSkip` when no regular application is available.
- 2026-08-31 — Isolated the stale-refresh race test from `NSWorkspace` as well; it now asserts the injected record snapshot directly and runs on every test host.
- 2026-08-31 — Tightened optional `isOnScreen` handling so missing or malformed values never become implicit `true`; ambiguous duplicate metadata remains CoreGraphics-only unless exactly one candidate is explicitly on screen.
- 2026-08-31 — Added one session-wide AX enrichment deadline, a deterministic re-press regression, and event-tap revocation propagation; the stale-refresh test now waits for the newer snapshot before releasing the older provider call.
- 2026-08-31 — Final hardening verification passed 36 Window Switcher tests, `make build-plugin PLUGIN=WindowSwitcher`, `make script-tests` (196 tests), and the standalone PluginKit v5 compatibility check. The latest global `make ci` XCTest phase reported ten failures outside Window Switcher: four `SystemStatusPluginTests`, three `DiskCleanPluginTests`, one `PluginPackageManifestTests`, and one `AppleShortcutsCommandRunnerTests` failure reported twice by the runner.
- 2026-08-31 — Sol contract review found ordering-dependent titleless geometry correlation, dropped AX-only surplus candidates, and direct-cycle re-press double counting. The merge now resolves exact matches first and retains only cardinality-surplus AX candidates; direct-cycle re-presses use one initial step, with deterministic reverse-direction coverage.
- 2026-08-31 — Added an injectable activation boundary and integration regressions for `.activateAllWindows`, current AX minimized state, and no-match CG-only fallback. The focused class now contains 41 tests; final repository gates are rerun after this hardening.
- 2026-08-31 — Final hardening resolves mixed titleless/cardinality merge cases, filters consumed AX candidates during geometry fallback, caps every AX messaging timeout by the shared deadline, and handles tap-disabled events after Accessibility revocation without re-enabling the tap. The focused class now contains 44 passing tests; `make build-plugin PLUGIN=WindowSwitcher`, `make script-tests` (196 tests), and PluginKit v5 compatibility pass. The latest `make ci` script phase passes; its XCTest phase still reports eight failures outside Window Switcher: four `SystemStatusPluginTests`, three `DiskCleanPluginTests`, and one `PluginPackageManifestTests`.
- 2026-08-31 — Final review hardening adds stable CoreGraphics window-number shortcut identities with controlled legacy AX migration, preserves distinct AX-only titles sharing bounds, skips CG revalidation for AX-backed entries, rejects stale cached records after refresh timeout, and owns cancellable activation tasks. The focused class now contains 51 passing tests; plugin build, script checks (196), and PluginKit v5 compatibility were rerun successfully.
- 2026-08-31 — Review follow-up removed automatic legacy ordinal migration so an ordering change cannot retarget a saved shortcut; legacy ordinal keys remain available for explicit reassignment. Application identity now compares optional launch dates directly, allowing the legitimate both-missing case while retaining PID, termination, bundle, and mismatch checks. The focused class now contains 52 passing tests.
- 2026-08-31 — Final review follow-up migrates a legacy first-window binding only when the current catalog has exactly one window for that application, leaves ambiguous legacy keys available for explicit reassignment, cancels application-level and AX-backed activations before any side effect, and compares launch dates only when both snapshots expose one. The focused class now contains 57 passing tests; the plugin build, script checks (196), and PluginKit v5 compatibility check pass.
- 2026-08-31 — Added explicit reassignment coverage for an ambiguous legacy first-window shortcut. The focused class now contains 58 passing tests. `make ci` again passed all 196 script checks, while its global XCTest phase reported nine failures outside Window Switcher: `PluginPackageManifestTests` x1, `SystemStatusPluginTests` x4, `DiskCleanPluginTests` x3, and `DeviceBatteryCommandRunnerTests` x1. Whitespace and bounded Graphify checks pass; the final standards/spec review is clear, while the two final Sol review workers did not return a result after bounded waits and were stopped.
- 2026-08-31 — Manual macOS acceptance used the installed Debug app with Accessibility granted. Its overlay listed two distinct Finder `Récents` entries while the live `.optionAll` CoreGraphics inventory identified one matching Finder record (`windowNumber 6617`) with `isOnScreen == false`; the active-Space record was `windowNumber 6681` with `isOnScreen == true`. The temporary `Control-Option-9` trigger was restored to the original `Command-Tab` binding. Selecting the exact inactive entry remains unverified through the accessibility driver, so it is recorded as a coverage limitation rather than a discovery-contract failure.
- 2026-08-31 — Final local standards/spec review found no actionable divergence from issue #357 or repository conventions. Threat review of CoreGraphics/Accessibility metadata, process identity, activation, cancellation, and permission-loss boundaries found no actionable security vulnerability. The 58 focused Window Switcher tests, plugin build, script checks, and whitespace checks are green. Two bounded independent review workers did not return and were stopped without a verdict; their absence does not replace the completed local reviews.

## Acceptance evidence

- Automated evidence: parser, merge, activation fallback, stale-refresh, direct-cycle, permission, and shortcut-tap regressions are covered by the focused Window Switcher XCTest class; build and repository gates are recorded in the PR journal below.
- Manual evidence and limitation: `make install-debug-app` installed the verified Debug app. With Accessibility granted, the real overlay listed two distinct Finder `Récents` entries while `.optionAll` reported one as `isOnScreen == false` (`windowNumber 6617`) and its active-Space peer as `isOnScreen == true` (`windowNumber 6681`). This proves inactive-Space discovery in the running UI. The accessibility driver could not reliably select the exact inactive entry, so AX restore/raise/focus and visual selection remain unverified; the corresponding focus acceptance criterion is intentionally unchecked.

## Current files

| Area | Files |
|---|---|
| Window discovery and activation | `Plugins/WindowSwitcher/Sources/WindowSwitcherAppCatalog.swift` |
| Window entry model | `Plugins/WindowSwitcher/Sources/WindowSwitcherModels.swift` |
| Shortcut and session lifecycle | `Plugins/WindowSwitcher/Sources/WindowSwitcherPlugin.swift` |
| Overlay state and cleanup | `Plugins/WindowSwitcher/Sources/WindowSwitcherOverlayController.swift` |
| Regression tests | `Plugins/WindowSwitcher/Tests/WindowSwitcherPluginTests.swift` |
| User-facing documentation | `README.md`, `changes/unreleased/` |

## Files to create or modify

- `Plugins/WindowSwitcher/Sources/WindowSwitcherAppCatalog.swift`
- `Plugins/WindowSwitcher/Sources/WindowSwitcherModels.swift`
- `Plugins/WindowSwitcher/Sources/WindowSwitcherPlugin.swift`
- `Plugins/WindowSwitcher/Sources/WindowSwitcherOverlayController.swift`
- `Plugins/WindowSwitcher/Sources/WindowSwitcherShortcutTap.swift`
- `Plugins/WindowSwitcher/Tests/WindowSwitcherPluginTests.swift`
- `README.md`
- `changes/unreleased/window-switcher-multi-space.md`
- `docs/features/INDEX.md`
- `docs/features/window-switcher-multi-space.md`

## Tests / QA

- Focused XCTest for the injected window-record parser, all-Space merge, final entry conversion, and stale-refresh race.
- `make build-plugin PLUGIN=WindowSwitcher`.
- `make ci` before publication, with any unrelated pre-existing failures attributed precisely.
- `git diff --check` and untracked-file whitespace validation.
- Manual Finder windows across two Spaces and Window Switcher invocation; exact inactive-entry selection remains a documented accessibility-driver limitation.

## Out of scope

- Changing Window Switcher modes, shortcut semantics, plugin permissions, or UI layout.
- Adding private macOS APIs, a new host/plugin protocol, a window manager, or Space navigation controls.
- Changing other plugins or resolving unrelated open PRs and test failures.
- Guaranteeing exact focus of a CoreGraphics-only window while macOS withholds its Accessibility element or changes its title/geometry; the public fallback activates the application and performs one immediate AX lookup when metadata matches.

## Keep updated when

- The discovery source, activation fallback, acceptance evidence, verification status, or publication state changes.
- A new platform limitation or product decision is discovered.

## History

<!-- Read only for regression, audit, or an explicit request. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-31 | `pending` | Bug fix | Cross-Space window discovery for issue #357 |
