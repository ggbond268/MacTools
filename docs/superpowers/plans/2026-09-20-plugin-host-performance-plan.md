# Plugin Host State and Shortcut Performance Plan

Date: 2026-09-20

Status: first implementation batch complete; regression and installed Dev validation recorded below. Broader provider caching remains deferred pending measurement.

This follows the installed Dev validation in the [Window Switcher performance plan](2026-09-20-window-switcher-performance-plan.md). The source examined is `PluginHost.swift` at baseline `35a1d98f`; the running Dev process includes the subsequent Window Switcher changes.

## Evidence and scope

Two independent Time Profiler recordings of Dev PID 26936, with no visible Dev window at the visibility probes, identify scheduled host updates as the largest sampled CPU group.

| Recording | Duration | Total Running sample weight | Main-thread weight | Scheduled host group |
| --- | ---: | ---: | ---: | ---: |
| Initial post-change recording | 20 s | 1,266 ms | 1,123 ms | 903 ms / 71.33% |
| Follow-up recording | 30 s | 1,365 ms | 1,192 ms | 948 ms / 69.45% |

In the follow-up, inclusive frames include `rebuildDerivedState` at 698 ms, `defaultPluginDescriptors` at 480 ms, `synchronizeActionRegistry` at 399 ms, `shortcutDescriptors` at 355 ms, `legacyResolvedBinding(forPluginID:shortcutDefinitionID:)` at 323 ms, `syncGlobalShortcuts` at 250 ms, and legacy plugin shortcut migration at 185 ms. These frames overlap and must not be added together. They are sampled work, not individual uninterrupted main-thread stalls or energy shares.

A five-minute info-level log query returned 46 synchronization messages, with the returned messages spanning 15:47:51–15:49:52. Each reported 52 providers and 287 catalog entries. The identical counts do not establish identical definitions or availability. The logs establish repeated full-size synchronization; source inspection establishes the repeated construction inside it.

This makes host updates the next supported optimization priority for the measured no-window Dev workload. It does not establish the largest cost during visible scrolling, startup, every plugin combination, or Release execution. The original dirty-plugin event sources are not identified by the asynchronous scheduled stack; instrument their IDs and causes before attributing the frequency to a particular plugin.

Artifacts: `/private/tmp/mactools-host-followup.trace`, `/private/tmp/mactools-host-followup.xml`, `/private/tmp/mactools-host-followup-summary.json`, `/private/tmp/mactools-host-followup-visibility.json`, and `/private/tmp/mactools-host-registry-check-info.ndjson`. Nightly remained a separate running process and is not included in these Dev stack weights.

## Confirmed repeated work at the baseline

1. `schedulePluginStateChangeRebuild()` coalesces events for 80 ms but then always calls both `rebuildDerivedState(dirtyPluginIDs:)` and `syncGlobalShortcuts()` (`PluginHost.swift:4175`). Dirty IDs limit panel snapshot reads; descriptor construction, ordering, permissions, action definitions, search entries, commands, and shortcut projections still have broad paths.
2. Descriptor helpers repeatedly derive the same inventory. `orderedPluginDescriptors()` calls both `descriptorsByID()` and `orderedPluginIDs()`, each reaching `defaultPluginDescriptors()`. That function allocates, localizes, filters, and sorts the plugin list. `shortcutDescriptors()` reaches this chain again (`:5243`, `:5291`, `:5341`).
3. `synchronizeActionRegistry()` reads every provider's definitions, catalog entries, and input descriptors on ordinary state changes (`:4220`). `ActionRegistry.synchronize` retains equal provider generations and conditionally increments its catalog revision, but it still reconstructs and validates the complete registry and assigns published values (`ActionRegistry.swift:95`).
4. Every phase-aware shortcut descriptor receives a binding callback during synchronization, even for an identical resolved binding (`PluginHost.swift:6256`). Window Switcher's callback resolves both bindings again. Each resolver lookup rebuilds the global shortcut descriptors and repeats conflict validation (`:5708`). System hotkey registrations already reuse unchanged Carbon bindings (`GlobalShortcutManager.swift:152`); the measured redundancy is predominantly above that layer.
5. Legacy migration completion is checked inside the store after the host has already evaluated each plugin's legacy assignment getter (`PluginHost.swift:4573`, `ActionShortcutAssignmentStore.swift:195`). The registry path and the subsequent shortcut path also both build the complete action shortcut presentation list.
6. Many derived arrays and registry publications are assigned even when their value is unchanged. The cost of these publications while visible must be measured separately from the confirmed background computation.

## Planned implementation sequence

### 1. Share one snapshot within a host update

Introduce a small main-actor update context for plugin descriptors, localized metadata, ID lookup, ordering, shortcut definitions, and conflict inputs. Build each shared collection once and pass it through the state rebuild, action synchronization, and shortcut synchronization. Resolver callbacks invoked during this update should use the same validated context instead of enumerating every plugin again.

Start with update-local reuse, which avoids long-lived cache invalidation assumptions. Discard or rebuild the context if plugin replacement or failure isolation changes the inventory during the update. Preserve guarded plugin calls and the existing recovery pass. Build the action shortcut presentation after registration settles, once per completed update.

### 2. Deliver binding changes only when their effective value changes

Compute effective bindings and global conflicts once. Track delivery by plugin object identity and shortcut ID, distinguishing an undelivered binding from a delivered `nil`. A new plugin instance receives its initial state even if its ID and binding match the previous instance. Clearing a binding, default changes, conflicts, import/reset, and removal must still update listeners immediately.

Retain system registration failure recovery. Existing listeners keep their normal permission, wake, activation, and recording lifecycle; repeated binding callbacks must not become their only recovery mechanism. Keep execution-time action availability checks live even when definitions are unchanged.

### 3. Separate provider structure from live state

After the first two changes are measured, retain per-provider snapshots of action definitions, catalog entries, input descriptors, and shortcut definitions. On `onStateChange`, reread the changed provider's relevant declarations and compare actual values. Apply structural registry changes only when those declarations or provider identity change. Recompute affected settings and command projections from these snapshots.

The existing callback does not distinguish presentation changes from structural changes. Dynamic declarations must therefore remain eligible for rereading; assuming every definition is immutable would break current behavior. Cross-provider conflicts and dependent workflow actions still need validation when their inputs change. Installation, removal, replacement, isolation/recovery, language, ordering, import/reset, and host panel/workflow changes require the appropriate wider invalidation.

Action availability, exposure/safety policy, and execution revision remain separate from catalog structure. Preserve `onActionSafetyStateChange` as a synchronous path. Preserve provider generations and input-session invalidation when a provider or definition changes. A stable catalog revision alone is insufficient grounds to skip availability or shortcut conflict work.

### 4. Move completed migration checks before payload construction

Let the assignment store expose its persisted migration-completion state, or accept a lazy payload producer that runs only while migration is pending. The existing store remains authoritative. Successful migration performs its cleanup exactly once; write failure and rollback retain retry behavior. Do not introduce a process-only completion flag that could conceal a failed write or a restored store.

### 5. Publish only meaningful presentation changes

Compare equatable value projections before assignment and keep structural, availability, shortcut, and presentation revisions distinct. Preserve updates when content changes under a stable ID. Models containing views, closures, or opaque plugin state need explicit invalidation rules; do not suppress updates using only IDs, counts, or hashes.

Apple's [SwiftUI performance guidance](https://developer.apple.com/videos/play/wwdc2023/10160/) supports reducing unnecessary dependencies and updates, followed by measurement. Here the first target is the source-confirmed main-actor computation. Retain the current short coalescing window and plugin actor isolation while removing redundant work.

## Validation and acceptance

- Count descriptor/definition reads, migration getter evaluations, binding callbacks, and registry publications for an unchanged state notification. Repeated callbacks must not reread unrelated providers within the same update.
- Preserve existing dynamic-action appearance/removal, parameterized catalog entries, immediate safety changes, language switching without plugin reload, and execution-time availability tests.
- Cover a replacement instance with the same plugin ID, failure isolation/recovery, initial `nil` binding delivery, cleared/restored bindings, dynamic defaults, shared bindings, reverse-cycle conflicts, and registration failure recovery.
- Verify migration success, already-completed migration, failed persistence, retry, and preferences restore without reading or mutating real user data.
- Compare no-window idle, ordinary input activity, visible menu panels, and settings navigation separately. Measure host-update duration and main-thread bursts alongside process CPU and wakeups; do not infer scrolling improvement from idle CPU alone.
- Run focused host/action/shortcut tests first. Cross-module implementation must pass the required script and integration checks, including the repository's CI-equivalent checks before any later push.

The first implementation targets steps 1, 2, and 4, plus safe value comparisons from step 5, then reprofiles before introducing broader provider caches. No percentage reduction is promised from the sampled host share.

## First implementation batch

- `PluginDescriptorSnapshot` shares localized metadata, ordering, ID lookup, and surface inputs within each synchronous rebuild. Shortcut registration takes a fresh snapshot for its separate phase. Neither snapshot survives a host update. The existing guarded calls, isolation filtering, and recovery pass remain active.
- `PluginShortcutBindingTracker` suppresses unchanged phase-listener deliveries by weak plugin identity, shortcut ID, and optional binding. Initial `nil`, replacement instances, removed and reappearing shortcuts, changed defaults, conflicts, and clearing still produce the appropriate delivery. Explicit assignment, import, and reset paths retain forced notifications. Tracking does not replace Carbon registration, failed-registration retry, permission handling, or execution-time availability checks.
- The assignment store exposes persisted migration markers. The host checks them before evaluating completed migrations' payload getters. Failed payload reads do not mark migration complete; failed persistence still retries without premature cleanup.
- Equatable action catalog, issue, and shortcut projections publish only when their contents change. Registry synchronization still refreshes provider callbacks and execution state. Equal catalog values do not short-circuit provider validation or live availability.
- The obsolete descriptor dictionary helper was removed. The notification tracker is a separate small type with focused lifetime and delivery tests; no PluginKit API or ABI changed.

This batch deliberately retains separate rebuild and registration phases, live definition reads, and both action-shortcut presentation passes. It does not introduce per-provider caches or change callback ordering. The unchanged-update test observes two shortcut-definition reads, one per phase. Additional elimination of registry or presentation work requires the next profile and a separate invalidation design.

### Regression validation

The 17 relevant host, action, localization, shortcut assignment, and registration test classes passed 213 tests. New coverage includes unchanged notification bursts, initial and cleared bindings, dynamic defaults, reappearing shortcuts, weak plugin lifetime and replacement identity, migration persistence/retry and failed getters, unchanged publications, and fresh availability callbacks with an unchanged catalog. Existing dynamic-action, immediate safety, permission, localization, and failure-isolation tests remain enabled.

Artifacts: `/private/tmp/mactools-host-regression.xcresult` and `/private/tmp/mactools-host-regression.log`.

`make script-tests` passed all 269 tests, including changelog and generated-plugin-data validation. `make generate`, the Debug app build, and `git diff --check` passed. The standard install flow updated the verified Dev app and skipped the unchanged Window Switcher package; no plugin-package update was needed for this host batch. The installed process for post-change measurement is PID 19401.

Validation applies to the host batch and the build installed at 16:24. Separate window/panel and PluginKit presentation edits were observed later in the shared workspace and were left intact; their later state is not covered by this batch's validation record. No commit was created.

### Installed Dev observations

The pre-change trace ran at 15:48:40–15:49:10 and the post-change trace at 16:26:52–16:27:22 (UTC+08:00). Both traces contain six returned registry synchronization log messages, each reporting 52 providers, 287 catalog entries, and no registry issues. Thus the lower host sample weight is not explained by fewer synchronization messages in these recording windows. Equal counts do not prove identical provider contents, availability, or external workloads. Start and end probes found no visible Dev windows.

| Running sample weight in a 30-second recording | Before | After |
| --- | ---: | ---: |
| Entire process | 1,365 ms | 794 ms |
| Main thread | 1,192 ms | 596 ms |
| Scheduled host group | 948 ms | 370 ms |
| Descriptor construction | 480 ms | 44 ms |
| Shortcut descriptor construction | 355 ms | 37 ms |
| Binding resolver by plugin and shortcut ID | 323 ms | 28 ms |
| Derived-state rebuild | 698 ms | 269 ms |
| Action registry synchronization | 399 ms | 160 ms |
| Global shortcut synchronization | 250 ms | 101 ms |
| Action shortcut presentation construction | 211 ms | 145 ms |

Function rows are inclusive and overlap; do not sum them. These are sampled CPU weights, not measured individual stall durations, input latency, or energy percentages. The descriptor and binding work targeted by this batch is substantially smaller in the new trace.

Three independent 40-second process-counter windows were retained:

| Window | Dev CPU, one core = 100% | Interrupt wakeups/second | Context |
| --- | ---: | ---: | --- |
| Before installation | 4.20% | 11.58 | Dev PID 26936; Nightly remained running |
| First post-installation window | 6.89% | 17.94 | Nightly exited during collection; one two-second Dev interval reached 54.27% CPU |
| Subsequent stable window | 2.92% | 13.40 | Dev PID 19401; Nightly was no longer running |

The first post-installation window is retained rather than discarded as an unfavorable result. External process state changed and a CPU burst occurred; these measurements do not establish its cause. The later observation shows lower average CPU than the baseline but higher wakeups, and the changed environment prevents a controlled percentage-savings claim. No power measurement or visible scrolling benchmark was performed. Post-restart physical footprint was 134.61 MiB in the stable window versus 225.24 MiB before installation; differing process lifetimes and workloads prevent attributing that difference to this patch.

Artifacts: `/private/tmp/mactools-host-after.trace`, `/private/tmp/mactools-host-after-summary.json`, `/private/tmp/mactools-host-trace-sync-counts.json`, `/private/tmp/mactools-host-before-clean.ndjson`, `/private/tmp/mactools-host-after-clean.ndjson`, `/private/tmp/mactools-host-after-stable.ndjson`, and the corresponding visibility JSON files. Build and script-test logs are `/private/tmp/mactools-host-install.log` and `/private/tmp/mactools-host-script-tests.log`.

### Next bounded work

The host remains the largest sampled group, at 370 ms / 46.60%, with action-shortcut presentation accounting for 145 ms inclusively. The broad descriptor repetition is no longer the dominant part. The next design should examine the two presentation passes and the causes of state notifications before adding persistent provider caches. Any consolidation must preserve callback ordering, immediately visible availability and conflicts, and the standalone rebuild/shortcut entry points. Identify dirty plugin IDs and notification causes before changing update frequency; a scheduled stack alone cannot identify the original source.

Keep the current batch independently reviewable. Broader registry invalidation and publication of opaque view-backed models remain separate work, with no claim that this batch eliminates visible UI stutters or establishes lower energy use.

The subsequent [background maintenance batch](2026-09-20-background-maintenance-optimization.md#completed-host-projection) consolidates the action-shortcut presentation and scopes shortcut-definition reuse to that projection. Its tests and installed Dev measurements are recorded separately; persistent per-provider snapshots remain deferred.
