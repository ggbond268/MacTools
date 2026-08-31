# Feature — Battery charge-control write reliability

Last verified: 2026-08-31

Status: ready-for-review
Source of truth: yes

## Summary

- Fix issue #341: the Battery Charge Limit plugin reports a force-discharge write failure instead of switching the Mac to battery power.
- Select the available SMC adapter-isolation key at runtime and use the value required by that key family.
- Do not fail a force-discharge operation because an additional readable compatibility key is not writable.
- Preserve the existing charging-limit modes, rollback behavior, privileged-helper verification, and localized error reporting.

## User flow

1. The user enables Battery Charge Limit on a Mac with a supported SMC charge-control path.
2. The user chooses force discharge while the battery is above the configured limit.
3. The helper selects the preferred available adapter-isolation key and writes its force-discharge value.
4. The plugin enters discharging mode without showing the current issue's write failure.
5. Stopping discharge clears available adapter-isolation keys so the Mac can use external power again.

## Acceptance criteria

- [x] Force discharge uses `CHIE=0x08` when `CHIE` is available, otherwise `CH0J=0x01`, otherwise `CH0I=0x01`.
- [x] Force discharge is reported as supported when any one of `CHIE`, `CH0J`, or `CH0I` is available.
- [x] A present but non-writable fallback key does not turn a successful selected-key write into a reported failure.
- [x] Stopping force discharge attempts to clear all known available adapter-isolation keys, ignores failures for readable inactive compatibility keys, and reports failure when an active or indeterminate key cannot be cleared.
- [x] Existing charging inhibit/resume paths and failure rollback remain unchanged, except that `resume` now surfaces an active or indeterminate force-discharge cleanup failure.
- [x] User-facing compatibility copy no longer claims that only `CH0I` is supported.

## Definition of done

- [x] Helper and plugin capability handling implement the key-selection contract.
- [x] Focused regression tests cover capability fallback and the user-visible discharge action.
- [x] Battery helper documentation, README, localization, and unreleased changelog describe the supported behavior.
- [x] Focused Battery Charge Limit and policy checks passed before the final shared-policy wiring; the package still builds after the final wiring.
- [x] Post-wiring XCTest execution of `BatteryChargeLimitPluginTests`, `BatteryForceDischargePolicyTests`, and `BatteryChargeLimitWriterTests` passes.
- [x] Separate standards/spec/security review completed; final review has no remaining P0–P3 findings.
- [ ] Manual SMC acceptance is recorded on compatible hardware, or the exact missing evidence is reported before publication.
- [ ] One focused pull request closes issue #341.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| Force discharge uses one compatible adapter-isolation key with its key-specific value | This file | `SMCHelper` force-discharge policy | Battery SMC helper |
| Any available adapter-isolation key enables the force-discharge action | This file | `BatterySMCCapabilities.canForceDischarge` | Battery Charge Limit plugin panel, settings, and actions |
| Cleanup clears known adapter-isolation keys best-effort while preserving failures for active or indeterminate keys | This file | `SMCHelper` force-discharge write path | Battery SMC helper resume and plugin cleanup |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-31 | Treat `CHIE`, `CH0J`, and `CH0I` as alternative adapter-isolation controls, with `CHIE` preferred | Existing helper writes `CH0I` and an optional `CH0J` together, while established SMC tooling uses key-specific fallback values | Avoids coupling success to an optional key and supports Macs whose active control is not `CH0I` |
| 2026-08-31 | Preserve cleanup failures for active or unreadable keys while ignoring failures for readable inactive compatibility keys | Clearing an inactive fallback must not mask a still-active force-discharge key | Prevents the UI from reporting a successful stop while force discharge remains enabled |
| 2026-08-31 | Keep the fix inside the existing privileged helper and capability model | The issue is a write-path compatibility defect; no new PluginKit or IPC contract is needed | Limits the PR to Battery Charge Limit sources, tests, and required documentation |
| 2026-08-31 | Do not update `docs/features/INDEX.md` in this shared workspace | The index already contains unrelated staged WindowSwitcher WIP and must not receive a mixed hunk | The standalone feature record remains the source of truth for this PR; index registration can be done separately if needed |

## Plan

- [x] P001 — Revalidate issue #341, canonical repository, open PRs, branches, and GitButler WIP.
- [x] P002 — Define the adapter-isolation key selection, capability, cleanup, test, and manual-QA contract.
- [x] P003 — Implement helper key fallback and update plugin capability handling.
- [x] P004 — Add focused regressions and update required documentation/localization.
- [x] P005 — Run verification, independent standards/spec/security review, and resolve findings.
- [ ] P006 — Commit only issue #341 changes and publish one focused PR.

## TODO

- [x] F001 — Add key-specific adapter-isolation selection and cleanup — files: `Plugins/BatteryChargeLimit/SMCHelper/Sources/main.swift` — status: done
- [x] F002 — Extend capability probing and user-facing capability presentation — files: `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitModels.swift`, `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitWriter.swift`, `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitPlugin.swift`, `Plugins/BatteryChargeLimit/Resources/Localizable.xcstrings` — status: done
- [x] F003 — Add regression coverage — files: `Plugins/BatteryChargeLimit/Tests/BatteryChargeLimitPluginTests.swift`, `Plugins/BatteryChargeLimit/Tests/BatteryForceDischargePolicyTests.swift` — status: done
- [x] F004 — Update documentation and release note — files: `Plugins/BatteryChargeLimit/SMCHelper/README.md`, `README.md`, `changes/unreleased/battery-charge-control.md` — status: done

## Journal impl Codex

- 2026-08-31 — Revalidated issue #341 as open with only a screenshot and one `+1` comment. No matching PR, branch, or BatteryChargeLimit WIP exists; shared WindowSwitcher changes remain outside this feature.
- 2026-08-31 — The existing helper writes `CH0I` and, when present, `CH0J` with the same value and treats any failure as fatal. The selected implementation will model `CHIE`, `CH0J`, and `CH0I` as ordered alternatives with key-specific enable values; real SMC behavior still requires hardware acceptance.
- 2026-08-31 — Implemented ordered adapter-isolation candidates in `Plugins/BatteryChargeLimit/SMCHelper/Sources/main.swift:249-409`: `CHIE` uses `0x08`, `CH0J`/`CH0I` use `0x01`, enabling stops after the first successful candidate, and cleanup attempts every available candidate while preserving active or indeterminate-key failures.
- 2026-08-31 — Extended `BatterySMCCapabilities` and helper probe output for `CHIE`/`CH0J`, updated generic SMC compatibility copy, added capability/action regressions, and updated the helper README, root README, and plugin changelog. `docs/features/INDEX.md` remains untouched because it contains unrelated shared WindowSwitcher WIP.
- 2026-08-31 — `BatteryChargeLimitPluginTests` passed and `make build-plugin PLUGIN=BatteryChargeLimit` passed. Manual force-discharge acceptance on compatible hardware remains pending; no real SMC write was attempted in this workspace.
- 2026-08-31 — `BatteryChargeLimitPluginTests`, `BatteryChargeLimitWriterTests`, `make build-plugin PLUGIN=BatteryChargeLimit`, `make script-tests` (196 tests), JSON validation, and whitespace checks passed. The full `make ci` gate reached XCTest after the script phase but exited 65 on these unrelated tests: `DiskCleanPluginTests.testCleanActionTitleReportsSelectionAndRemovalMode`, `DiskCleanPluginTests.testConfirmingPhaseReplacesCleanActionWithConfirmAndCancel`, `DiskCleanPluginTests.testTrashCompletionSubtitleDoesNotClaimSpaceWasReclaimed`, `PluginPackageManifestTests.testRichProjectedManifestDecodesProductMetadata`, `AppleShortcutsCommandRunnerTests.testTimeoutForceKillsTermIgnoringDescendantAndDrainsPipes`, `SystemStatusPluginTests.testMenuBarFormatterUsesCustomizedMetricValuesAndOrder`, `SystemStatusPluginTests.testMenuBarFormatterUsesSelectedOrder`, `SystemStatusPluginTests.testMenuBarNetworkRatesStayWithinCompactWidthReservation`, `CLIHostBridgeCallbackRelayTests.testRejectedRegistrationReconnectsWithoutResettingBackoff`, and `SidecarPluginTests.testDeactivationRecoveryTerminalizesPendingOperationAndAllowsRetry`; no Battery Charge Limit failure was reported.
- 2026-08-31 — Security review found and corrected cleanup masking: a successful inactive-key clear can no longer hide a failed active or unreadable-key clear. Targeted verification must be rerun after this change.
- 2026-08-31 — Extracted the force-discharge policy into `Plugins/BatteryChargeLimit/SMCHelper/Sources/BatteryForceDischargePolicy.swift`, shared by the helper and plugin test target, and added deterministic coverage for key order/values, enable fallback, inactive-key cleanup failures, and active-key cleanup failures.
- 2026-08-31 — Follow-up review required unknown non-zero SMC values to be treated as indeterminate, and required `resume` to propagate active or indeterminate cleanup failures instead of swallowing them.
- 2026-08-31 — Applied the follow-up safety fixes: shared `activeState` treats zero as inactive, the selected enable byte as active, and other non-zero bytes as indeterminate; `resume` now propagates force-discharge cleanup errors after attempting all keys.
- 2026-08-31 — Post-wiring `make build-plugin PLUGIN=BatteryChargeLimit`, `make script-tests` (196 tests), `swiftc -parse` for the shared policy/tests, JSON validation, and whitespace checks passed. The targeted XCTest command was blocked before test execution by the unrelated `WindowSwitcherApplicationControlling` conformance failure in existing WindowSwitcher WIP; no Battery test failure was reported.
- 2026-08-31 — Final independent Sol review against base `9197035650b67f1c313960e8b1dded7a710264dd` returned `CLEAR` with no remaining P0–P3 findings; the only open validation item is compatible-hardware SMC acceptance.
- 2026-08-31 — User authorized publication while unrelated WindowSwitcher WIP remains in the shared checkout. The issue branch will include only Battery Charge Limit hunks; the PR will explicitly retain the post-wiring XCTest and compatible-hardware SMC limitations.
- 2026-08-31 — The post-wiring focused XCTest rerun passed all Battery Charge Limit, force-discharge policy, and writer tests. The latest `make ci` still exits 65 only on unrelated `FanControlPluginTests.testMonitoringOnlyPublishesMeaningfulSnapshotChanges`, `PluginPackageManifestTests.testRichProjectedManifestDecodesProductMetadata`, three `SystemStatusPluginTests` formatter/width tests, and three `DiskCleanPluginTests` action/subtitle tests; the runner duplicated one Fan Control failure.

## Current files

| Area | Files |
|---|---|
| Privileged SMC helper | `Plugins/BatteryChargeLimit/SMCHelper/Sources/main.swift` |
| Shared force-discharge policy | `Plugins/BatteryChargeLimit/SMCHelper/Sources/BatteryForceDischargePolicy.swift`, `Plugins/BatteryChargeLimit/project.yml` |
| Capability model and writer | `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitModels.swift`, `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitWriter.swift` |
| Plugin presentation and actions | `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitPlugin.swift` |
| Regression tests | `Plugins/BatteryChargeLimit/Tests/BatteryChargeLimitPluginTests.swift`, `Plugins/BatteryChargeLimit/Tests/BatteryForceDischargePolicyTests.swift` |
| Documentation and localization | `Plugins/BatteryChargeLimit/SMCHelper/README.md`, `README.md`, `Plugins/BatteryChargeLimit/Resources/Localizable.xcstrings`, `changes/unreleased/battery-charge-control.md` |

## Files to create or modify

- `Plugins/BatteryChargeLimit/SMCHelper/Sources/main.swift`
- `Plugins/BatteryChargeLimit/SMCHelper/Sources/BatteryForceDischargePolicy.swift`
- `Plugins/BatteryChargeLimit/project.yml`
- `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitModels.swift`
- `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitWriter.swift`
- `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitPlugin.swift`
- `Plugins/BatteryChargeLimit/Tests/BatteryChargeLimitPluginTests.swift`
- `Plugins/BatteryChargeLimit/Tests/BatteryForceDischargePolicyTests.swift`
- `Plugins/BatteryChargeLimit/Resources/Localizable.xcstrings`
- `Plugins/BatteryChargeLimit/SMCHelper/README.md`
- `README.md`
- `changes/unreleased/battery-charge-control.md`
- `docs/features/battery-charge-control.md`

## Tests / QA

- Focused `BatteryChargeLimitPluginTests` for alternative capability support and discharge action availability.
- Focused `BatteryForceDischargePolicyTests` for key selection, fallback, and cleanup failure semantics.
- `make build-plugin PLUGIN=BatteryChargeLimit`.
- `make script-tests` and the repository's required PR gate.
- `jq empty Plugins/BatteryChargeLimit/Resources/Localizable.xcstrings`.
- `git diff --check` and an equivalent whitespace check for untracked files.
- Manual compatible-hardware check of force-discharge on/off, battery power state, charging restoration, and failure logging.

## Out of scope

- New SMC key families beyond `CHIE`, `CH0J`, and `CH0I`.
- Changes to charging-limit key semantics (`CHTE`, `CH0B`/`CH0C`, or `BCLM`).
- UI redesign, new settings, PluginKit/API changes, dependency changes, helper installation redesign, or version bumps.
- Changes to other plugins, unrelated WIP, existing PRs, or global test failures outside this commit lot.

## Keep updated when

- The helper key order/value contract, capability presentation, tests, manual evidence, or publication state changes.
- A platform-specific SMC limitation or product decision is discovered.

## History

<!-- Read only for regression, audit, or an explicit request. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-31 | `pending` | Bug fix | Reliable adapter-isolation writes for issue #341 |
