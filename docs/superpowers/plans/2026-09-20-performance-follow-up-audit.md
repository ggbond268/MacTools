# Application and plugin performance follow-up

Status: analysis only. No application or plugin implementation changes are part of this audit.

Latest source revalidation: `main` was fast-forwarded from `6675d10f` to `7fa6d668` with `git pull --ff-only origin main`. See the final section for updated findings. The measurements below precede that pull and must not be reported as measurements of `7fa6d668`; source line numbers in the original sections refer to the earlier checkout.

## Scope and conclusion

The current source still has actionable performance opportunities. The strongest targets are the host's general state/action/shortcut pipeline, plugin-owned subscriptions in retained hidden component views, and Window Switcher's recurring catalog maintenance. These have runtime evidence. Lower-frequency hardware reads, audio polling, and statistics persistence have narrower or conditional evidence and should follow the measured hotspots.

The first source review ended on `main` at `6675d10f65ac36a2101646a9626f4592af96d71b`, including the earlier performance work in `6031f64c`. The checkout advanced during that review; it was clean before this document was added. The source and measurements complement the [September 19 audit](2026-09-19-application-performance-audit.md), without replacing its historical results.

The running application was MacTools Dev 1.3.1 (70), PID 31553, launched September 19 at 23:53:44.783, with an executable built at 23:53:26. Its embedded exact source revision was not independently established. It is a Debug build on macOS 27.0 (26A428), not a controlled Release benchmark. No preferences or plugin enablement were changed for this audit.

## New measurements

WindowServer queries succeeded before and after each capture. They reported the matching Dev application inactive and no visible windows belonging to it. These endpoint checks do not constitute continuous visibility monitoring. The user could still interact with other applications; this is an application-background observation, not a guaranteed keyboard/mouse-idle system benchmark.

| Capture | Result | Interpretation |
| --- | --- | --- |
| `top`, 80 seconds, 40 two-second intervals after discarding the initial zero | CPU mean 20.57%, median 21.5%, range 2.4–42.4% | Remaining variable background work; 100% represents one logical core |
| Memory during the same capture | Approximately 198–201 MB, ending at 198 MB | No sustained upward trend in this short window; not a leak test |
| Separate `sample`, 25 seconds, 10 ms interval | 2,178 main-thread stack samples; 96 included scheduled host updates, 36 action/shortcut catalog construction, 52 catalog refresh | Stack inclusion counts include waits and must not be interpreted as CPU utilization |
| Physical footprint reported by `sample` | 197.9 MB, lifetime peak 234.0 MB | Different process/lifetime from the prior audit; no before/after memory claim |
| Registry log query, 00:06:07–00:06:34 | Four synchronizations, each with 52 providers and 255 catalog entries | The previous roughly once-per-second cascade is reduced, but each remaining synchronization is still substantial |

The separate 15-second Time Profiler capture contained 1,765 samples classified as Running, with a 1 ms weight each. Of these, 1,614 were on the main thread. The following groups are mutually exclusive: the host group takes precedence over plugin functions invoked inside that group.

| Running-sample classification | Sample weight | Share |
| --- | --- | --- |
| Scheduled host state update, including shortcut synchronization | 1,132 ms | 64.1% |
| Window Switcher maintenance outside the host update group | 477 ms | 27.0% |
| App Volume audio scan | 34 ms | 1.9% |
| Activity Bar work outside the preceding groups | 20 ms | 1.1% |
| Other SwiftUI render work | 11 ms | 0.6% |
| Fan Control SMC reading | 2 ms | 0.1% |
| Other work | 89 ms | 5.0% |

These are statistical CPU sample weights from one capture, not exact operation durations, energy measurements, or expected percentage savings. They must not be equated to the separate `top` intervals. Action/shortcut catalog construction accounted for 465 ms inside the host group and is not an additional group.

Of Window Switcher's 477 ms, 380 ms were on the main thread and 97 ms on workers. Inclusive system frames included `NSRunningApplication.activationPolicy` (156 ms), `NSRunningApplication.icon` (70 ms), and `NSWorkspace.iconForFile:` (64 ms). These nested values must not be added together.

A separate 12-second SwiftUI recording after prior panel use contained seven transaction groups: six `Transaction` groups and one `Transaction for unknown action`. Durations were 11.236, 4.886, 2.109, 35.786, 31.029, 15.344, and 31.394 ms, totaling approximately 131.8 ms. It also contained seven preference and seven display-list groups. Named update records included System Status, Device Battery, and Activity Bar component views. The trace's 6,310 internal update records are not a count of frames or body evaluations. No new manual foreground scrolling or switching trial was performed.

## 1. P1: Reduce the scope of ordinary plugin state updates

**Evidence:** measured dominant CPU path and confirmed source structure.

- `Sources/Core/Plugins/PluginHost.swift:4149` coalesces callbacks, then invalidates availability, rebuilds derived state, and synchronizes shortcuts on the main actor.
- The dirty-plugin set narrows panel snapshot evaluation, but the remainder still traverses common descriptors, permissions, action registrations, settings search entries, commands, and settings pages.
- `synchronizeActionRegistry()` builds action/shortcut rows at line 4264; `syncGlobalShortcuts()` builds them again at line 6213.
- `corePlugin(for:)` at line 3323 searches the plugin array. Catalog row construction repeatedly resolves and localizes owner metadata through `actionOwnerTitle(providerID:)` at line 6320.
- Activity Bar's input notification at `Plugins/ActivityBar/Sources/ActivityBarController.swift:407` publishes both `objectWillChange` and generic host state after a 750 ms coalescing window, without visibility gating. Battery Charge Limit's monitor at `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitPlugin.swift:780` calls the generic callback every five seconds even when the presented state is unchanged. These are source-confirmed producers; this capture does not attribute every host transaction to one producer.

**Direction:** first remove unchanged plugin notifications and reuse indexed descriptor/owner/permission data within a coherent update. Separate frequently changing presentation data from action definitions, shortcut bindings, permission state, and settings structure. Existing plugins must retain a conservative full-invalidation fallback; an optional change-domain contract can be introduced incrementally if local fixes are insufficient.

Catalog row construction should occur after the relevant synchronization phases have settled. Do not simply delete its second invocation or key a cache only by catalog revision: shortcut binding callbacks can change availability and action state. Permission revocation, plugin lifecycle changes, dynamic actions, shortcut conflicts, and automation consumers must continue to observe current state.

Activity Bar must keep capturing input and screen time. Battery Charge Limit must keep evaluating and enforcing transitions. Reduce unnecessary publication rather than stopping their functional work.

## 2. P1: Gate plugin-owned hidden presentation subscriptions

**Evidence:** directly observed hidden SwiftUI work, independently of the host presentation gate.

`Sources/App/MenuBarPanelPresentationModel.swift:11` suppresses host-driven publication when the panel is hidden. It does not intercept observable objects inside cached plugin views:

- `Plugins/SystemStatus/Sources/SystemStatusPlugin.swift:825`: the component observes the sampling view model.
- `Plugins/DeviceBattery/Sources/DeviceBatteryComponentView.swift:6`: the component observes its view model and store.
- `Plugins/ActivityBar/Sources/ActivityBarComponentView.swift:152`: the component observes the controller and presentation state; chart construction is part of its retained body.

The new trace identifies System Status snapshot publication and Device Battery collection publication as transaction causes, and records Activity Bar/chart updates while no app window was visible. This does not contradict a previous fresh-process trace with no hidden updates: retained view history and plugin-owned subscriptions are separate dimensions.

**Direction:** retain the underlying data model and required monitoring, but introduce surface-specific presentation snapshots/subscriptions that stop publishing when their consumer is hidden. Catch up from the latest snapshot when it becomes visible. Apply the rule to embedded components, details, settings, and previews according to each consumer's actual visibility.

Retain scroll offsets, chart selection, navigation state, and editing state. The visibility value passed when a cached view is initially created is not a sufficient ongoing lifecycle signal. Likewise, `onDisappear` alone is insufficient for retained views hidden using opacity. Keep visible menu-bar readings updating even when their dashboard is hidden.

`Sources/App/ConfiguredMenuBarPanelContent.swift:86` also retains visited tabs in a `ZStack`; they share the panel presentation model. While one tab is visible, a host revision can still invalidate previously visited inactive tabs. A per-tab presentation boundary is a reasonable follow-up, but its incremental cost has not yet been measured in a multi-tab interaction trace.

## 3. P1/P2: Make Window Switcher catalog maintenance incremental

**Evidence:** second-largest independent CPU group in the new trace; main-thread application metadata and publication work remain after moving AX reads to workers.

`Plugins/WindowSwitcher/Sources/WindowSwitcherAppCatalog.swift:571` installs a one-second refresh. `refresh()` enumerates running applications and reads dynamic metadata; each worker result reconstructs entries, accesses application icons/names, and rebuilds the combined publication. The initial refresh, individual worker completions, and all-Spaces completion can each rebuild that publication. The all-Spaces path also notifies after each successful refresh.

**Direction, ordered by risk:**

1. Reuse application identity/icon/name metadata per process lifetime, invalidating for termination, PID reuse, relaunch, and metadata changes. Snapshot display topology once per relevant update rather than resolving it for every window.
2. Coalesce publication work from a burst of worker completions, with prompt publication for interaction-critical changes. Avoid rebuilding equivalent results.
3. Use existing AX/workspace events to target affected processes. Keep a slower reconciliation fallback for missed notifications and unsupported applications; maintain prompt first-open, focus, recency, and Space-change behavior. Only adjust cadence after testing these cases.

`Plugins/WindowSwitcher/Sources/WindowSwitcherWindowRecords.swift:263` waits for an asynchronous result by sleeping for 10 ms repeatedly. A completion-driven, cancellation-aware wait with the same deadline and bounded in-flight work could reduce wakeups. It is secondary to repeated scanning and publication.

Do not stop discovery whenever the switcher is closed: that could harm first-open latency and recent-window order. Preserve fresh identity/permission checks before activating, closing, or quitting a target. Background discovery and action authorization must not share stale-data assumptions.

## 4. P2: Narrow remaining settings dependencies

**Evidence:** source-confirmed broad observations, plus visible-settings host work in the prior audit. No new foreground gesture timing was captured here.

`Sources/App/SettingsView.swift:960` and line 989 observe the entire host for app shortcut rows. Plugin detail/form pages do the same at lines 3801 and 3942; additional shortcut, backup, and cloud rows retain similar dependencies. A live reading in another plugin can therefore invalidate UI that only needs a particular settings projection.

**Direction:** extend the existing navigation/marketplace projection approach to selected-plugin settings and specific row groups. Publish only when the fields consumed by those views change. Keep action commands separate from observed data, and provide indexed lookup for the selected plugin. Include locale, permission, validation, dynamic control structure, and custom-content revision in invalidation rules.

Do not replace the sidebar's native list again without a remaining list-specific trace. Do not use shallow equality on page IDs or closures to suppress updates: it can leave controls and permission guidance stale. Prioritize the host pipeline and hidden component subscriptions before broad UI rewrites.

## 5. P2: Remove avoidable main-thread I/O from presentation paths

**Evidence:** source-confirmed blocking paths; small sample presence, not a dominant CPU group in this capture.

- `Plugins/FanControl/Sources/FanControlPlugin.swift:546` reads SMC synchronously on the main actor every ten seconds, or every two seconds while its primary detail is visible. `FanControlSMCReader.swift:101` rereads fan limits and probes temperature keys; unsuccessful key-information lookups are not cached.
- `Plugins/BatteryChargeLimit/Sources/BatteryChargeLimitPlugin.swift:156` queries installed-helper availability while building action definitions. `BatteryChargeLimitWriter.swift:159` reads both installed and bundled helper files for comparison, including on the cached-path branch. Fan Control's writer uses the same validation pattern. The sample caught Battery Charge Limit's helper check inside host registry work.

**Direction:** serialize SMC access on a dedicated worker that owns the connection, publishing completed snapshots on the main actor. Reuse stable hardware discovery with reconnect/wake invalidation and retry transient failures. Publish an asynchronously refreshed helper-availability snapshot for UI/catalog use, with file/lifecycle invalidation.

Actual privileged execution must still perform its required helper verification and recover correctly from replacement or removal. A UI availability cache must never authorize privileged execution. Keep fan limits, control behavior, charging transitions, and sleep/wake recovery unchanged. Moving a read off the main actor improves responsiveness but does not by itself reduce the total work.

## 6. P2: Bound statistics persistence work without deleting history

**Evidence:** confirmed storage design; current sample cost is small and long-history impact is unmeasured.

`Plugins/ActivityBar/Sources/ActivityBarCodingSessionStore.swift:123` persists after each hook event; `flushActiveDurations()` also persists. Its line 561 encodes the entire `days` dictionary and calls storage from the main actor. Historical coding aggregates remain in memory. The separate input store retains 370 days and debounces persistence for 30 seconds, but `ActivityBarStatsStore.swift:280` still serializes the full dictionary on the main actor.

**Direction:** skip unchanged writes; move snapshot encoding to a serialized worker with ordered completion and generation protection. For sustained hook volume or large history, consider per-day storage or a journal plus checkpoints so old aggregates need not be rewritten for each event. Preserve event counts, overlap accounting, reset/rollback behavior, backup compatibility, and required flush/durability semantics.

Do not silently prune coding history to obtain a lower memory number. Measure history size and allocation cost first; if it is significant, preserve history on disk with bounded in-memory access. Increasing debounce alone would change the crash-loss window and is not automatically a behavior-preserving optimization.

## 7. P2/P3: Reduce audio polling and lifecycle wakeups selectively

**Evidence:** App Volume scan is measured but small (34 ms, 1.9% of running samples); lifecycle opportunities are source-based.

`Plugins/AppVolume/Sources/CoreAudioApplicationMonitor.swift:56` performs a full Core Audio process scan every second on a utility queue, already with 150 ms leeway and equality-suppressed delivery. `refresh()` can enqueue additional scans. `stop()` at line 78 synchronously waits on that queue from the main actor, so a slow scan can delay deactivation.

**Direction:** coalesce requests and make teardown asynchronous with lifecycle generation checks. Investigate Core Audio process-list, output-activity, and device property listeners, retaining a bounded fallback for unsupported or unreliable notifications. Continuous application-volume routing must still discover new output and handle device changes when the panel is closed. The existing off-main scan and equality guard are useful and should remain.

The host already exposes `PluginApplicationActivityStateHandling`. Nonessential scans in Window Switcher, App Volume, System Status, and enabled Launchpad hot-corner monitoring do not currently adopt that hook. Audit actual session-inactive/display-asleep demand before suspending any work; restore promptly and preserve playback, automation, history expectations, and safety-related monitoring. A locked/sleeping-device power trial was not part of this pass.

## Areas that do not justify immediate rework

- System Status already distinguishes foreground/menu-bar/background sampling: fast samples are 3/3/30 seconds and ordinary background slow/process/history work is 300 seconds. Device Battery already has demand-based sampling, system observers, and 300-second background intervals. Their hidden presentation subscriptions are the stronger target than another blanket frequency reduction.
- AI Usage already checks active/provider/activity demand, uses timer tolerance, and backs off failures. A 30-second scheduler tick is not proof of a network request every 30 seconds.
- Accessibility permission polling is shared, one-second, has 0.5-second tolerance, and only publishes trust changes. Clipboard polling uses change detection and tolerance; reducing capture frequency could miss short-lived clipboard states.
- The prior main/Duo status-icon feedback loop was not present in the new sampled call chains. No additional icon renderer rewrite is justified by this capture.
- Clipboard embedded previews already have an eight-entry/32 MiB budget and memory-pressure eviction; rich-text previews retain only the last bounded result. Window previews have an eight-entry/30-second lifetime bound. Launchpad's icon cache has a 512-entry bound. These are not evidence of unbounded leaks.
- Retained component/settings views trade memory for reopening latency and interaction-state preservation. The observed 198–201 MB plateau does not justify destroying all cached views on close.

## Suggested implementation order and validation

1. Optimize host publication scope and unchanged producers, and gate plugin-owned hidden presentation updates. These directly address both UI contention and background work.
2. Reuse Window Switcher metadata and coalesce publication before changing discovery cadence.
3. Narrow remaining settings projections, then address measured I/O/persistence and audio lifecycle costs in separate focused changes.

Compare the same optimized build, plugin set, preferences, window history, and machine conditions. Separate no-window/no-input background, no-window typing, visible static panels, settings scroll/switching, and multi-tab interactions. Record CPU sample attribution, main-thread transaction duration/hitches, wakeups, and physical footprint. Use repeated open/close cycles to test memory stabilization and a longer window to include 30-second/300-second collectors. Direct power measurement is required before claiming a battery-life gain.

Functional verification should follow each changed boundary: live readings catch up on open; hidden views preserve state; shortcut/permission changes propagate; window targets and recency remain correct; audio routing follows new processes/devices; charging/fan control and statistics durability remain intact. This analysis-only pass did not require a new build or XCTest run.

## Primary references and local evidence

Apple's [SwiftUI Instruments session](https://developer.apple.com/videos/play/wwdc2025/306/) recommends inspecting update causes and their CPU work before choosing an optimization. Its [timer energy guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) supports event-driven notification, stopping unnecessary timers, tolerance, and avoiding polling as synchronization. [Core Audio property listeners](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistener(_:_:_:_:)) provide a mechanism to investigate for audio state changes; notification completeness still needs validation for the supported OS versions and selected properties.

Local raw captures are temporary and intentionally not committed:

- `/private/tmp/mactools-followup-runtime.top.txt`
- `/private/tmp/mactools-followup-idle.sample.txt`
- `/private/tmp/mactools-followup-action-registry.ndjson`
- `/private/tmp/mactools-followup-hidden-swiftui.trace`
- `/private/tmp/mactools-followup-timeprofile.trace`
- Matching `mactools-followup-*.start.json` / `*.end.json` visibility probes

The numerical summaries above preserve the useful evidence if those temporary files expire. Raw trace metadata and environment listings should not be copied into the repository.

## Revalidation after pulling main at 7fa6d668

### Baseline and evidence boundaries

`git pull --ff-only origin main` succeeded. Both local `main` and `origin/main` resolved to `7fa6d66812f8c80df16cd1ef60e32552fa77e8cf`. The existing untracked audit document was preserved. The incoming changes affected 51 files, primarily Window Switcher, Clipboard item shortcuts, host shortcut conflict handling, and related tests.

This pass reviewed the incoming diff, current call paths, and adjacent test coverage. It did not rebuild/relaunch the application or run new performance captures or XCTest. In particular, the earlier 64.1% host and 27.0% Window Switcher sample shares are historical evidence, not a claim about the new revision's CPU distribution.

### Improvements already present in the new code

- Window Switcher checks worker identity and running state again after awaited helper scans, preventing stopped or superseded scans from publishing. AX worker identity is preserved separately from WindowServer ownership. The new catalog tests cover both behaviors.
- `WindowSwitcherSpaceMembership.classify(records:)` shares one managed-desktop topology read per inventory, including a failed topology read, and refreshes it on the next inventory. `WindowSwitcherWindowRecordsTests.testInventorySharesTopologyAndRefreshesItOnNextScan` explicitly checks the read count. Preserve this design. This is Space classification, separate from the remaining per-window `NSScreen` display-context lookup.
- Window Switcher now snapshots application metadata once per process per refresh instead of accessing it for every window entry. The scope of that snapshot has also expanded to all running application objects, creating the separate opportunity below; net cost needs measurement.
- Clipboard's shortcut getter returns fixed definitions plus `cachedItemShortcutDefinitions`; it does not build the entire history index on each getter read. Its existing large-history test uses 10,000 history items and 100 assignments, but measures repeated getter access after loading, not cache refreshes or host synchronization.
- Item shortcut expiration uses one task scheduled for the next expiration. It does not introduce a new periodic polling loop.

### Revised priorities

| Priority | Finding at the new revision | Evidence |
| --- | --- | --- |
| P1 | Host update scope and repeated shortcut descriptor/catalog work remain | Current call paths; prior runtime attribution only |
| P1 | Hidden plugin-owned UI subscriptions remain unchanged | Relevant files unchanged by the pull; prior hidden-view trace |
| P1/P2 | Window Switcher still scans every second and eagerly reads unused helper presentation metadata | Current source; new revision's net CPU impact unmeasured |
| P2 | Clipboard notifications rebuild shortcut-related history indexes even without item assignments | Newly introduced callback path |
| P2, burst-sensitive | Batch expiration/removal resets host shortcuts one at a time, repeatedly rebuilding global state | Complete synchronous call chain verified in source |
| P2/P3 | Settings projections, Activity Bar persistence, SMC/helper I/O, audio scan teardown | Implementations unchanged; earlier qualifications still apply |

### Host: preserve new conflict semantics while reducing duplicate work

At `Sources/Core/Plugins/PluginHost.swift:4155`, the scheduled path still invokes derived-state rebuilding and global shortcut synchronization. Action shortcut catalog rows are built at lines 4270 and 6253. The newly added `globalShortcutRegistrationSelection(for:)` is used once for settings conflict presentation at line 3941 and again for actual registrations at line 6232.

The new selection logic preserves explicit customization precedence and intentionally shared bindings. It is required behavior, not removable overhead. Share its inputs/results within a coherent binding revision rather than dropping validation. Catalog/availability publication must still occur after callbacks that can change execution state.

There is another useful local boundary: `legacyResolvedBinding(forPluginID:shortcutDefinitionID:)` at line 5689 calls `shortcutDescriptors()` for a single binding lookup. Event-shortcut validation can construct the descriptors again. Reuse an indexed descriptor snapshot where lifecycle and binding revisions are stable; invalidate it on dynamic definition changes, including Clipboard item shortcut changes. A permanently cached plugin-ID-only result would be incorrect.

### Window Switcher: avoid unused presentation metadata before reducing scan frequency

`Plugins/WindowSwitcher/Sources/WindowSwitcherAppCatalog.swift:569` now constructs an `Application` for every nonterminated object from `NSWorkspace.runningApplications`. This eagerly reads `icon`, localized name, hidden/active state, bundle identity/path, launch date, and activation policy on the main actor every refresh. The one-second timer remains at line 635.

Helper ownership mapping requires identity and bundle information, but the helper scan path at lines 715–723 only takes the helper's launch date from its application record. It renders helper windows using their host application's metadata. Eagerly loading presentation icons and names for all helpers is therefore unnecessary for that path.

Use lightweight identity records for process mapping and materialize host display metadata only where it is consumed. Cache appropriate fields per PID plus launch identity, with explicit invalidation for relevant metadata changes. Keep helper discovery and AX ownership intact. Do not restore the old regular-app-only discovery filter, because that would discard the new helper-owned-window coverage.

The host/helper mapping also has repeated pure work: `WindowSwitcherProcessMapping.Snapshot.helpers(for:owningWindowsIn:)` at line 25 rebuilds the set of record owners on every call, and `rebuildPublication()` calls it for each host after individual scans. Build owner/helper indexes once per record/mapping snapshot and coalesce publication where appropriate. These are narrower changes than changing the discovery interval. The completion wait in `WindowSwitcherWindowRecords.swift:262` still polls every 10 ms and remains a secondary candidate.

### Clipboard: optimize cache maintenance, not the already cached getter

`Plugins/ClipboardHistory/Sources/ClipboardHistoryPlugin.swift:570` invokes pruning and `refreshItemShortcutDefinitions()` on controller notifications, and the saved-library callback does the same. `pruneItemShortcutsWhenReady()` at line 1860 constructs complete item-ID sets. `refreshItemShortcutDefinitions()` at line 2662 constructs history/snippet dictionaries and rebuilds every assigned shortcut's title and description. Those index-building loops still run when `assignments` is empty.

The work is linear in loaded history/snippet count plus assigned shortcuts per notification. This is a confirmed scaling path, not evidence that the new getter is quadratic or that a new timer scans history continuously.

First provide a correct empty-assignment path that clears stale definitions while avoiding unrelated index work. Then use content/membership revisions and changed IDs to refresh only affected assigned items; preserve updates after deletion, expiration, rename, OCR changes, import/restore, and temporary load failure. Changes that only affect usage/collection status should not rebuild unrelated shortcut titles. Test cache maintenance and capture bursts separately from the existing getter benchmark.

### Clipboard: batch removal can multiply synchronous host rebuilds

The source chain is:

`ClipboardItemShortcutStore.removeWhere` / `removeAll` -> `onRemoved(removed)` -> a loop of `PluginSettingsContext.resetShortcut` calls (`ClipboardHistoryPlugin.swift:552`) -> `PluginHost.resetShortcut(for:)` (`PluginHost.swift:2197`) -> `applyShortcutCustomization` -> synchronous `rebuildDerivedState()` and `syncGlobalShortcuts()` (`PluginHost.swift:5987`).

For N registered removed assignments, this can perform N complete host rebuild/synchronization pairs, followed by ordinary state notification. It bypasses the normal coalescing used for `onStateChange`. Expiration after an inactive interval, clearing many assignments, or removing many referenced entries can therefore produce a main-thread burst. Actual duration on the new build has not been measured.

A host-supported batch mutation can update the bindings and registrations coherently and publish final state once. Removed/expired shortcuts must become unusable promptly, and conflict ownership must be recomputed correctly. Preserve backup suspension, rollback, and stale-paste protections; simply delaying removal notifications is not an equivalent fix.

### Memory implications of the new feature

Shortcut-retained History items are intentionally exempt from the ordinary count/payload retention budget (`ClipboardHistoryModels.swift:1301`). Thus the configured ordinary History limit is not a total bound on all retained content. This is part of shortcut durability, not by itself a memory leak.

Retain payloads lazily, preserve bounded decoded-preview caches, and avoid unnecessary full-history temporary indexes. If retained content materially grows, measure its metadata and payload-residency separately before considering storage changes. Do not prune active shortcut targets under the ordinary History budget, because that would break the feature.

### Next implementation scope

Start with shared host snapshot/index reuse and hidden presentation subscriptions. Add targeted Window Switcher identity/presentation separation, Clipboard's empty/incremental maintenance path, and batched shortcut removal as independent changes. Validate on the pulled revision before choosing scan-frequency changes or claiming new CPU/memory savings. The source review does not justify a broad rewrite or removing functionality.

## Implementation on top of `7fa6d668`

The follow-up implementation takes the bounded changes below. It does not change monitoring intervals, AX discovery policy, history retention guarantees, or action availability checks.

- Host shortcut validation reuses descriptors already read for the current phase. Action-catalog construction resolves provider titles and permission requirement tables once per construction, while still resolving per-action requirements and live availability. Both catalog publication phases remain because binding callbacks can change execution state.
- `PluginObservedContent` gives each retained presentation its own visible-only subscription. System Status, Device Battery, and Activity Bar adopt it; the shared collectors continue publishing for other consumers. The component host supplies visibility for closed panels, inactive tabs, and dashboards covered by inline details. Settings previews remain live, and reopening catches up without replacing the view identity.
- Activity Bar separates throttled statistics notifications from configuration/error changes. Hidden input events still update and persist the business snapshot but no longer trigger repeated global host reconstruction. Both primary and component surfaces refresh presentation when shown, and either visible surface keeps host count labels current. Opening the primary row does not force an additional synchronous history write.
- Window Switcher retains lightweight identity information for all helpers and reads display metadata only for a host that can start a scan. It refreshes that metadata each scan rather than adding an indefinitely cached icon/name. A helper-owner index is rebuilt when records or process mapping changes, shared across worker selection and publication, and cleared on stop. Existing scan lifetime guards and AX ownership are preserved.
- Clipboard shortcut maintenance caches only assigned targets, keyed by both collection revisions and target IDs. Pruning and title generation share that lookup; an empty assignment set does not index history. Payload retention, load-error guards, rename/OCR invalidation, backup suspension, and paste serialization remain unchanged.
- `PluginShortcutResetRequesting` adds an optional host callback for bulk removal. Each reset retains validation and binding-change callbacks, but common host presentation and final registration synchronization run once. Registrations are removed before returning. Existing PluginKit value layouts are unchanged.

The new presentation APIs require host 1.3.1. System Status, Device Battery, and Activity Bar declare that floor; Clipboard already did. The minimum-host inventory and contributor documentation cover both additive capabilities. Obsolete per-host helper scans and the duplicate action-assignment check after shared shortcut validation were removed.

### Verification record

- Nine new focused tests passed, including a real `NSHostingView` test that observes hidden rendering and retained local state, independent presentation subscriptions, bounded descriptor reads, synchronous batch unregistration, hidden statistics persistence, host-only metadata reads, clipboard target rename/deletion, and the bulk-reset callback.
- Repository script checks passed: 269 tests. Changelog validation passed.
- The frozen PluginKit v6 binary compatibility client passed.
- The related functional run completed with **608 passed, zero failed, and one opt-in screenshot test skipped** (`testCaptureClipboardAppearanceForReview`). It covers host components, action registry, failure isolation, shortcut assignment, System Status, Device Battery, Activity Bar, Window Switcher, Clipboard, and retained panel presentation.
- The existing 10,000-item/100-assignment clipboard getter benchmark passed separately: **one passed, zero failed**. Thus 609 distinct related tests passed. After the final primary-row adjustment, all 30 Activity Bar plugin and observed-content tests passed again.
- Workspace test launch initially waited in `dyld` before entering app code on macOS 27 beta. Identical compiled artifacts launched from a temporary directory completed the focused tests. A broad run also waited in Xcode's `CoreSymbolicationDT` while reporting a performance measurement, and another paused while reading a source catalog. The functional run ultimately completed, followed by the separate benchmark. Full-symbol generation was attempted and stopped during the same I/O wait; it was not needed for the successful runs. No test was removed or weakened to avoid these waits.
- The signed Debug app was rebuilt without stale XCTest bundle artifacts and installed successfully. The final running process is PID 36591, MacTools Dev 1.3.1 (70); no full Nightly app process was running.

### Runtime observations after implementation

Two `top` observations each contain twenty two-second intervals after discarding the initial zero sample. WindowServer probes before and after each interval found no on-screen windows belonging to the sampled app.

| Observation | CPU mean | CPU median | CPU range | `top` memory |
| --- | ---: | ---: | ---: | ---: |
| Existing installed Dev, PID 10601, before replacement | 21.49% | 19.40% | 6.90–44.50% | 186–190 M |
| Final patched Dev, PID 36591 | 6.46% | 5.25% | 3.50–13.00% | 132–136 M |

CPU 100% denotes one core. These are short observations on the same machine, not a controlled benchmark: the original installed binary's exact source revision was not recorded, app uptime differs, and user input and other workloads were not replayed. In particular, restarting changes retained views and caches, so the memory difference must not be attributed entirely to the patch or presented as a leak fix. No direct energy measurement was taken.

A 15-second Time Profiler recording near the attempted dashboard open contained 1,894 ms of running sample weight, including 1,607 ms on the main thread. Exclusive groups, assigning host stacks first, were host 906 ms, Window Switcher 721 ms, Device Battery 75 ms, App Volume 39 ms, System Status 14 ms, Activity Bar 7 ms, and other work 132 ms. This still identifies host updates and window discovery as candidates for future profiling; it does not justify reducing discovery or notification guarantees.

The URL-triggered dashboard request was not confirmed visible by either WindowServer probe, and there were no matching route-rejection diagnostics. Therefore this trace is **not evidence of foreground scrolling, visible-panel frame rate, or a successful manual interaction test**. The real SwiftUI hosting test verifies the presentation subscription/state behavior; human scrolling and switching still need a comparable interactive trial.

Local diagnostic artifacts are under `/private/tmp/mactools-performance-*`: the functional and benchmark `.xcresult` bundles, final Activity Bar result, script/ABI logs, before/after `top` samples and visibility probes, and the final time-profile XML/summary. Earlier measurements above remain historical and must not be substituted for measurements of this patch.

## Follow-up: current Energy Impact remains high

The user reported high Activity Monitor Energy Impact after commit `35a1d98f`. This follow-up sampled the existing processes without rebuilding, restarting, disabling plugins, or changing preferences. Dev was still PID 36591, version 1.3.1 (70). Nightly had subsequently been started as PID 60547, version 1.3.1 (33.1); the earlier single-instance condition no longer applied. WindowServer probes before and after Dev profiling found no on-screen Dev windows.

### Current process measurements

A separate 40-second observation used `proc_pid_rusage(RUSAGE_INFO_V4)` at two-second intervals. CPU time was converted using this machine's `mach_timebase_info` ratio (125/3 ns per tick), with one core equal to 100%. These were live-machine observations, not replayed workloads or a controlled comparison between the two builds.

| Process | Mean CPU | Two-second CPU range | Interrupt wakeups/s | Physical footprint |
| --- | ---: | ---: | ---: | ---: |
| Dev | 13.31% | 3.97–39.61% | 17.66 | 237.85–241.42 MiB |
| Nightly | 97.61% | 94.34–99.01% | 42.35 | 168.28–168.42 MiB |

A later independent `top` observation (ten two-second intervals after discarding the initial sample, with no profiler attached) measured Dev at 9.34% mean CPU, ranging from 2.2% to 33.1%. The two intervals demonstrate variable sustained work, not a fixed idle percentage. Its output is retained as `/private/tmp/mactools-energy-dev-confirmation.top.txt`.

Dev's disk-read, disk-write, and logical-write counters did not advance during this interval. No power assertion owned by Dev or Nightly appeared in `pmset -g assertions`. This does not exclude intermittent I/O, indirect system-service work, or GPU energy outside the sampled interval. Interrupt wakeups are not equivalent to full-package wakeups or timer firings; package-idle wakeup counters did not advance while the machine was busy.

Apple defines [Energy Impact](https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac) as a relative measure of current consumption, distinct from the 12-hour average. Its [energy measurement guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html) identifies CPU, network activity, and disk I/O among its inputs. The user's reported current impact should therefore not be dismissed as a stale historical average. Direct `powermetrics` per-process energy output was unavailable without an administrator password; no power-in-watts claim is made.

### Dev CPU attribution

A subsequent 20-second Time Profiler capture contained 1,149 ms of Running sample weight, including 961 ms on the main thread. The following groups are exclusive, with host work taking precedence over plugin calls made inside that work. These percentages describe sampled CPU stacks, not shares of energy or guaranteed optimization savings.

| Group | Running sample weight | Share |
| --- | ---: | ---: |
| Window Switcher discovery/publication | 730 ms | 63.53% |
| Scheduled PluginHost updates | 307 ms | 26.72% |
| App Volume | 41 ms | 3.57% |
| System Status | 19 ms | 1.65% |
| Activity Bar | 14 ms | 1.22% |
| Other / unresolved | 38 ms | 3.31% |

1. **Window Switcher is the largest current Dev hotspot.** `WindowSwitcherAppCatalog.start()` retains a one-second background scan. `DiscoveryEnvironment.applications` reads `NSWorkspace.runningApplications`, filters every entry using `isTerminated`, and reads bundle identity, bundle path, launch date, and activation policy. The application-inventory path accounts for 430 ms; `isTerminated` alone appears in 207 ms and LaunchServices information calls in 354 ms, with overlapping inclusive counts. These are synchronous main-actor reads even though AX window reads run on worker queues. `rebuildPublication()` contributes another 105 ms and is called after individual application scans as well as the all-Spaces scan. The prior fix eliminated unused helper presentation reads, but did not eliminate repeated inventory reads or repeated full publication.
2. **Host updates remain unnecessarily broad.** The scheduled rebuild plus shortcut synchronization accounts for 307 ms. `dirtyPluginIDs` limits panel snapshot getters, while shared descriptor construction, ordering, localization, action registration, migration input construction, and shortcut processing still traverse many plugins. Logs contain 39 registry synchronizations between 14:26:46 and 14:28:33, each with 52 providers and 287 catalog entries; this is observed logging, not proof of every callback's origin. Binding callbacks re-enter the host resolver, whose descriptor lookup can scan all plugins again. The trace includes both Window Switcher binding reconfiguration and legacy Screenshot/Translator migration getters in that path.
3. **Audio polling is secondary in this capture.** App Volume scans Core Audio process state once per second, accounting for 41 ms. System Status and Activity Bar are substantially smaller here. The short trace does not rank less frequent collectors or prove they are free of problems.

The dominant remaining work is background discovery and shared host computation. Around 84% of the sampled Running work is on the main thread, which also competes with user interaction when a panel is opened. This capture does not measure foreground scrolling latency or establish that retained SwiftUI rendering is the current bottleneck.

### Nightly is a separate high-load process

A separate ten-second `sample` of Nightly found 694 of 1,247 main-thread observations (55.7%) under `NSStatusItem._updateReplicantsUnlessMenuIsTracking`, including snapshot drawing and appearance updates. Its app symbols were stripped, so the exact initiating app function was not established. This is a different hotspot from the Dev profile and is consistent with the earlier status-item investigation. Nightly's load adds substantial whole-machine energy usage but must not be reported as Dev's process CPU or as proof that it caused Dev's score.

### Next bounded optimization priorities

- Window Switcher: retain a process-lifetime inventory with explicit launch/exit invalidation and bounded reconciliation; avoid repeated static identity lookups; coalesce complete-list publication across scan completions. Preserve helper ownership, PID reuse protection, Space changes, permission revocation, missed-notification recovery, and invocation freshness. Change fallback frequency only after validating notification coverage and activation behavior.
- PluginHost: reuse descriptor/localization/ordering snapshots within an update, separate structural catalog changes from ordinary state updates, and avoid unchanged binding callbacks and already-completed migration reads. Keep live action availability and shortcut conflict checks authoritative, and invalidate caches for language changes, plugin replacement/isolation, ordering, and configuration changes.
- Recheck one installed build and one active instance under the same plugin set. Measure no-window idle, user-input activity, and visible-panel interaction separately. A release-optimized build comparison can quantify Debug overhead; it cannot excuse the source-confirmed repeated work.

Artifacts: `/private/tmp/mactools-energy-dual-rusage.ndjson`, `mactools-energy-dual-summary.json`, `mactools-energy-dev-live.trace`, `mactools-energy-dev-live.xml`, `mactools-energy-dev-live-summary.json`, `mactools-energy-dev-registry.ndjson`, and `mactools-energy-nightly-live.sample.txt`. The raw usage counters are retained alongside converted CPU values. No production code changed during this investigation.

The subsequent [Window Switcher performance plan](2026-09-20-window-switcher-performance-plan.md) records the cache, notification recovery, invocation-freshness, and cross-Space requirements for reducing repeated discovery work.

The [Plugin Host performance plan](2026-09-20-plugin-host-performance-plan.md) records the next host-focused implementation batch, its 213-test regression run, and installed Dev measurements. Its results supersede this investigation's host-cost observations for that newer build; the original measurements above remain historical evidence.
