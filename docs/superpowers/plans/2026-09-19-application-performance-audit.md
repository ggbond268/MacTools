# Application performance audit and optimization plan

Status: targeted fixes implemented, with the original analysis preserved below and implementation results recorded afterward. A sustained panel interaction trace and an optimized-build comparison remain separate validation tasks.

## Assessment

The highest-value work is reducing persistent host/catalog rebuilds and redundant status-icon updates, including Duo Status's independent item. These are present with no visible MacTools window as well as with settings visible. Hidden menu-bar SwiftUI updates are independently confirmed and justify narrowing presentation subscriptions. The current evidence does not justify replacing SwiftUI List or disabling functional background monitoring.

| Priority | Change | Evidence | Scope |
| --- | --- | --- | --- |
| P1 | Deduplicate unchanged app and Duo Status icon rendering | Repeated observer-driven updates and AppKit replication; the first implementation retest isolated Duo Status's remaining loop | Local controller fixes; preserve all rendering inputs |
| P1 | Suppress unchanged Window Switcher host notifications and consolidate host action/shortcut work | One-second notification paths in code, approximately one-second registry logs, large sampled catalog cost | Preserve window discovery/recency and action freshness; two separable fixes |
| P2 | Narrow retained panel subscriptions and content/layout publication | Instruments transaction causes and hidden panel update descriptions | Focused presentation refactor; retain interaction state |
| P2, conditional | Narrow remaining settings row/page dependencies | Broad host observations remain; initial navigation/marketplace projections already improved | Use complete semantic snapshots/revisions, not shallow closure equality |
| Investigation only | Move Fan Control SMC reads off the main actor; deduplicate formatted System Status metric layout | Code risks, not measured dominant hotspots | Implement only if measured durations justify the change |

Remaining performance validation: sustained panel scrolling/tab switching with Hitches data, an optimized-build comparison after each fix, and longer sampling for 30-second/300-second work. No blanket claim about all 60 plugins, overnight energy, GPU cost, or operating-system defects is made.

## Scope

- Date: September 19, 2026, Asia/Shanghai.
- Checkout base: `main` at `c1423fb909e2`, with existing local edits. The running Dev cohorts are distinguished by PID/build time below; this is not a pristine-main or Release benchmark.
- Application: MacTools Dev 1.3.1 (70), PID 62828.
- Process launch: 22:31:11.657. Executable built at 22:30:52.
- Nightly was absent from the process inventory before the baseline.
- The same Dev process was used for all three samples.
- Earlier two-instance samples used another Dev process/build and are not a controlled before/after comparison.
- The initial sampling did not change source code or application preferences. The user selected pages and scrolled during the indicated phases.

## Measurements

`sample` collected main-thread call stacks every 10 milliseconds. Percentages below are shares of sampled stacks, not frame-drop rates or precise elapsed-time attribution.

| Phase | Start | Duration | Main-thread samples | Scheduled plugin state rebuild, including shortcut synchronization | Action/shortcut catalog construction (included in preceding column) | AppKit status-item replication callback | App status-icon update |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Idle, General selected | 22:35:08 | 8 s | 557 | 35.0% | 16.9% | 27.1% | 6.3% |
| Sidebar scrolling, General selected | 22:39:53 | 12 s | 824 | 38.8% | 18.9% | 16.3% | 2.2% |
| Settings page switching | 22:41:25 | 12 s | 848 | 37.4% | 18.0% | 25.4% | 5.1% |

The first `top` observation was discarded because it reports zero CPU before an interval is available. Remaining process CPU readings were 54.2%, 97.2%, and 96.5% around the idle capture; 46.6%, 75.2%, 75.3%, and 75.7% around scrolling; and 48.0%, 74.8%, 76.0%, and 77.2% around switching. These intervals overlap or immediately follow the stack captures rather than having identical boundaries. Process CPU uses one logical core as 100%. System CPU remained substantially idle; swap usage was zero in the initial inventory.

An adjacent 20-second idle log query returned 22 action-registry synchronizations, each reporting 52 providers and 255 catalog entries. This is approximately one synchronization per second, with occasional additional updates.

## Findings

### Persistent host work

`PluginHost.schedulePluginStateChangeRebuild()` calls `rebuildDerivedState(dirtyPluginIDs:)`, followed by `syncGlobalShortcuts()`. Both paths construct the action/shortcut catalog. This repeated computation appears in all three samples, including idle.

`WindowLayoutsPlugin.permissionRequirementIDs(for:)` reconstructs `actionDefinitions` to check membership. This path also appears in the catalog-construction stacks. A direct membership check could preserve behavior while avoiding definition construction and localization for every lookup.

The evidence supports reducing this persistent main-thread work before changing sidebar containers or extending refresh delays. Any consolidation must preserve catalog publication after shortcut synchronization and callers that rebuild state without synchronizing shortcuts. Dynamic actions, permission changes, binding errors, and migrations still require fresh results.

### Status-item updates

Every sampled `MenuBarStatusItemController.updateStatusIcon()` call in these captures came from the asynchronous callback installed by `configureStatusItem()` on `MenuBarIconAppearanceObserverView`. The observer responds to appearance/backing-property notifications without comparing the effective rendering context.

The fallback rendering path reassigns the status-item length, button image, and image position even when the payload is unchanged. The resulting AppKit layout and status-item replication work is visible in the samples.

The saved Dev preferences had no primary plugin icon owner and selected a remote asset with one frame. This does not support blaming an animated icon. Repeated appearance notifications plus unconditional assignments suggest a redundant-update or feedback path, but sampling alone does not establish the exact notification cycle or an operating-system defect.

A potential fix should deduplicate unchanged rendering inputs while preserving appearance, display scale, icon selection, animation frames, automation indicators, tooltips, accessibility labels, and status-item recreation.

### Sidebar and page switching

Scrolling did exercise native scrolling/table preparation paths. `NSTableView.prepareContentInRect:` accounted for 48 of 824 main-thread samples (5.8%); this is not the complete cost of rendering the sidebar. Page-specific construction did not emerge as the dominant sampled work during switching.

This evidence does not justify replacing SwiftUI List or globally retaining all plugin pages. It does not rule out additional layout costs or short interaction-specific hitches.

## Limits and next validation

- These are Debug-build samples, not a Release performance benchmark.
- Frame times, hitch counts, and click-to-render latency were not measured.
- Samples identify substantial shared main-thread work; they do not prove that either candidate explains every reported hitch.
- Apply one targeted change at a time, run functional regressions, and repeat idle/scroll/switch measurements with the same build configuration and plugin set. Use an optimized build for the final user-experience comparison.

## Raw evidence

- `/private/tmp/mactools-settings-single-baseline.sample.txt`
- `/private/tmp/mactools-settings-single-baseline.top.txt`
- `/private/tmp/mactools-settings-single-baseline.registry.ndjson`
- `/private/tmp/mactools-settings-single-scroll.sample.txt`
- `/private/tmp/mactools-settings-single-scroll.top.txt`
- `/private/tmp/mactools-settings-single-switch.sample.txt`
- `/private/tmp/mactools-settings-single-switch.top.txt`

## Proposed implementation sequence

1. Deduplicate fallback status-item rendering. Track the effective appearance, backing scale, payload/frame, active-state decoration, and automation indicator. Coalesce observer callbacks and skip unchanged AppKit assignments. Reset the key when recreating the status item. Verify static assets, animated assets, primary plugin ownership changes, light/dark appearance, multiple display scales, tooltips, accessibility, and automation state. Measure this independently before attributing any improvement to host changes.
2. Consolidate action/shortcut catalog construction within a host update transaction. Preserve the post-synchronization binding/error result, provider callback ordering, migrations, and callers that only rebuild derived state. Replace Window Layouts permission membership through freshly constructed action definitions with equivalent direct ID membership. Test built-in/custom/removed action IDs, permissions, conflicting assignments, and dynamic catalog changes.
3. Reduce unnecessary change propagation at its sources. Separate a plugin's private live data publication from host-visible state, and publish host changes only when the relevant semantic snapshot changes. Continue sampling and maintaining correctness even when no window is visible. Do not infer that an unchanged title means unchanged action availability.
4. If remaining measurements justify it, introduce narrow panel presentation models and explicit structural/layout revisions. Retain scroll/selection/detail state while preventing unrelated plugin updates from rebuilding visited hidden tabs. Keep plugin views and non-equatable control closures fresh; do not apply shallow equality to entire plugin pages.
5. Only after the preceding changes, consider an additive PluginKit change-domain/revision API. Existing plugins' generic `onStateChange` must retain its conservative behavior. New domains could separate panel data, settings data, action definitions, availability, permissions, and shortcuts. A compatibility-first rollout is preferable to an all-at-once host rewrite.

Every stage requires a separate before/after run with the same configuration. Functional acceptance includes plugin install/update/removal, permission revocation, shortcut recording/conflicts, dynamic actions, localization, display changes, window reopen, panel editing, and live settings values. Performance acceptance is reduced idle work and fewer redundant updates without delayed interactions; no numerical speedup is promised before remeasurement.

This sequence was the original proposal. The implementation pass below combined the first bounded host/presentation fixes, then measured and fixed the remaining Duo Status hotspot separately. The combined first pass does not isolate each individual change's CPU benefit.

### Refactoring boundary and validation

The evidence supports small rendering/notification fixes and a focused separation of host publication responsibilities. It does not support replacing SwiftUI, rewriting the entire plugin host, globally caching arbitrary plugin closures, or disabling background features. Stop after the small fixes if optimized-build measurements show acceptable CPU and interaction latency; an additive PluginKit API is conditional, not a mandatory prerequisite.

Use lightweight signposts/counters for notification source, dirty-plugin count, rebuild duration, action-catalog build count, actual icon assignments, and panel visibility. Record identifiers/counts only, without user data or action parameters. This would close the remaining attribution gap between source callbacks and the coalesced host task. Avoid logging per mouse/input event.

Relevant regression suites include `MenuBarStatusItemControllerTests`, `MenuBarIconSettingsTests`, `PluginHostActionRegistryTests`, `ShortcutAssignmentServiceTests`, `GlobalShortcutManagerRegistrationTests`, `PluginHostComponentSupportTests`, `PluginHostApplicationActivityTests`, `MenuBarPanelPresenterTests`, `PanelViewportStackTests`, and adjacent Window Switcher/Window Layouts plugin tests. Run only the suites affected by each implementation stage. If a public PluginKit contract changes, also run `make script-tests` and the compatibility inventory checks; use `make ci` before pushing cross-module changes. The initial documentation/profiling pass did not change runtime behavior; the subsequent implementation and its test results are recorded below.

## Broader audit: source findings

### Window Switcher can amplify a one-second poll into global host work

`WindowSwitcherAppCatalog.start()` installs a one-second fallback timer while the feature is enabled and Accessibility is available. Each refresh performs per-process AX work off the main actor through workers and refreshes the all-Spaces records. Two publication paths are significant:

- `refreshAllSpaces()` invokes `onChange` after every completed read, without checking whether the published result changed.
- A per-process completion invokes `onChange` when entries changed **or the application is active**, even when its entries are equal.

`WindowSwitcherPlugin.catalogDidChange()` ends with generic `onStateChange`, which schedules the host-wide work measured above. This establishes a code path capable of sustaining updates when no MacTools page is open. The approximately one-per-second registry logs are consistent with this path, but aggregate logs alone do not attribute every refresh to this plugin.

Keep the window catalog current and preserve recency, foreground focus, initial discovery completion, unavailable-state changes, permission revocation, and an open switcher session. The first optimization should compare the complete relevant publication/host state before notifying. Replacing the polling strategy needs separate evidence and must retain fallback coverage for unreliable AX notifications and other Spaces.

### Menu-bar panels retain views and observe the broad host

`ConfiguredMenuBarPanelsContent` retains visited tabs in a `ZStack`; inactive tabs use opacity and hit-testing changes. Both the container and each configured tab observe the full `PluginHost`. Host derived-state rebuilds assign several published arrays and unconditionally send `menuBarPanelContentDidChange`. The presenter then resolves selection and layout even when its popover is closed.

There are useful safeguards already: component views are cached, `PanelViewportStack` limits mounted items, selected details retain their anchors, panel-model updates compare values, and popover dismissal propagates visibility to plugins. Therefore neither eager destruction of all retained views nor a wholesale container replacement is justified. A narrower content/layout publication boundary is the candidate; actual offscreen SwiftUI work remains to be measured.

### Background work needs feature-specific policies

| Area | Existing policy | Audit interpretation |
| --- | --- | --- |
| System Status | Actor-based sampling; fast interval 30 s in background, 3 s for menu metrics/foreground; background slow/process/history work 300 s | Already distinguishes demand. Configuration changes notify the host; ordinary sample publication goes to its own view model. Do not blame it for every host rebuild. |
| Device Battery | Sampling demand from visible component or low-battery monitoring; background 300 s, visible Bluetooth 60 s/mobile 90 s; event observers and sleep/session handling | Preserve notification monitoring. Concurrent edits exist in this area and are outside this audit's changes. |
| Fan Control | SMC reads on the main actor; 2 s while expanded/visible, 10 s otherwise; meaningful snapshot comparison | Potential main-thread I/O candidate. Measure duration before moving ownership to a serialized worker; preserve preset enforcement and sleep/wake behavior. |
| Window Switcher | One-second catalog fallback plus workspace/AX events while enabled | Confirmed redundant-notification path; direct AX/catalog cost and host amplification need separate attribution. |
| Activity Bar | Records input immediately; host/UI notification coalesced over 750 ms | Bounded, but still not visibility-aware. Keep input accounting; consider avoiding host notifications for purely private statistics. |
| App Volume | CoreAudio scan on a utility queue every second with 150 ms leeway; equal snapshots suppressed | Reasonable isolation already. Verify lifecycle and actual scan cost before changing detection freshness. |
| Clipboard History | Change polling every 0.5 s, timer tolerance; retention scheduled separately | Necessary background function when enabled. The helper's 20 ms watchdog is a memory-safety mechanism and is not evidence of an always-running application poll. |
| Duo Status / AI Usage | Timer tolerance and private snapshots; AI Usage checks activity/provider demand | Monitoring safeguards exist. The later retest isolated and fixed Duo Status's standalone icon redraw loop; see implementation results below. |
| Keep Awake | Session-scoped assertions; timed-state display refresh aligns with minute boundaries | Required behavior. Do not disable it to improve idle measurements. |

### Measurement plan and interpretation

- Record PID/build/configuration/plugin count for every run. A new Dev process (PID 12565, executable built at 22:54:39) appeared after the original settings session; its data belongs to a separate cohort.
- Measure no-window idle, component/menu panel idle, panel interaction, General settings idle, and settings switching. Record whether the app is active; no visible MacTools page does not mean its enabled background features are inactive.
- Avoid concurrent Xcode builds during controlled measurements. Log machine idle CPU, memory/swap, and relevant helper activity. Never stop unrelated processes to manufacture favorable numbers.
- Use process CPU separately from thread stack proportions. Use the SwiftUI/Hitches instruments for actual rendering latency where available. Do not infer frame rate from `sample`.
- Short captures identify frequent work; 30-second/300-second samplers and sleep/wake behavior require longer or targeted runs. Energy impact, thermal throttling, and overnight idle remain unproven by short CPU samples.

## Broader audit: runtime evidence

### No visible MacTools windows

The second cohort used Dev PID 12565, launched at 22:54:59.337, with 52 action providers and 255 catalog entries. A read-only AppKit/CoreGraphics probe confirmed that the process existed, matched the Dev bundle, was inactive, and owned no on-screen windows. The WindowServer query succeeded and returned other windows; an empty result was not assumed to mean a successful query. The machine had 10 logical CPUs, 64 GiB RAM, and zero swap. No Xcode build was listed immediately before this capture.

At 23:00:15.772, a 12-second stack capture recorded 836 main-thread samples:

| Path | Samples | Share of main-thread samples |
| --- | ---: | ---: |
| Scheduled host update, including shortcut synchronization | 300 | 35.9% |
| Action/shortcut catalog construction, included above | 143 | 17.1% |
| AppKit status-item replication callback | 230 | 27.5% |
| App status-icon update | 32 | 3.8% |
| Window Switcher catalog refresh on the main thread | 12 | 1.4% |
| Main run-loop wait | 62 | 7.4% |

All 32 sampled app icon updates again originated in the appearance/backing observer callback. An adjacent 20-second log window contained 21 registry synchronizations. This reproduces the shared hotspots with no visible MacTools page; settings rendering alone cannot explain the sustained work.

CPU was measured in a separate following interval, without `sample` running: 61.8%, 97.1%, 95.9%, 96.7%, 96.4%, and 97.3% after discarding the initial zero observation. Machine idle CPU was about 69–71%. The app's physical footprint was about 153 MB in this short window; this does not constitute a memory-leak or long-term energy test.

### Hidden panels still receive SwiftUI updates

A separate 12-second Instruments SwiftUI capture in the no-window state recorded 18 `Transaction` groups, plus 18 preference groups and 18 display-list groups. All 18 transaction cause stacks pointed through `PluginHost.primaryPanelIndicatorsByID.setter`. The group-duration sum was 142.71 ms and the largest group was 9.11 ms; the sum is not exclusive CPU time or end-to-end latency.

The exported internal update descriptions included `ConfiguredMenuBarPanelContent`, `ComponentPanelContent`, `ComponentGridView`, `MenuBarContent`, `FeatureRowView`, and `PanelViewportStack`. This confirms actual hidden-view update work in addition to the source-level broad observation. The instrument classified the 11,785 exported internal records as `Other Updates`; they must not be described as 11,785 body evaluations or rendered frames. No hitches were recorded in this no-window capture, which says nothing about scroll smoothness with a visible window.

### Initial component-panel observation

At 23:06:56.342, the user opened the component panel. The initial window probe showed the app active, a 342 x 639 panel, a 360 x 298 auxiliary panel, and the 1040 x 720 settings window behind them. The 12-second sample contained 867 main-thread samples: 56.1% in scheduled host updates, including 27.1% in action/shortcut catalog construction; 12.0% in AppKit status-item replication; and 2.2% in app icon updates.

The panel had closed by the end-state probe. CPU observations also spanned this transition (49.8–98.3%, excluding the initial zero), with machine idle CPU varying from about 48% to 62%. This run establishes that host work remains prominent during panel use, but it is **not** a clean steady-state panel-versus-background CPU comparison. A separate interaction trace is needed.

An earlier dashboard deep-link attempt did not leave a panel visible at verification and is excluded from panel conclusions. General settings navigation did create the expected settings window. Raw filenames alone are not treated as proof of the displayed state.

### General settings visible while another app is active

A further eight-second sample of PID 12565 began at 23:11:15.454 with only the 1040 x 720 settings window on screen and MacTools inactive. It contained 580 main-thread samples: scheduled host work 196 (33.8%), including action/shortcut catalog construction 92 (15.9%); status-item replication 152 (26.2%); and app icon updates 23 (4.0%). All icon updates again came from the appearance/backing observer callback.

Adjacent CPU observations were 50.2%, 96.8%, 97.9%, and 96.8% after the initial zero; machine idle CPU was about 69–71%. Sustained process CPU was similar to the no-window cohort. This does not measure an active scroll gesture, but it strengthens the conclusion that persistent shared work dominates the baseline in both states.

### Local artifacts for the second cohort

- `/private/tmp/mactools-app-background-provisional.sample.txt`
- `/private/tmp/mactools-app-background-provisional.top.txt`
- `/private/tmp/mactools-app-background.registry.ndjson`
- `/private/tmp/mactools-app-background-swiftui.trace`
- `/private/tmp/mactools-app-background-swiftui-groups.xml`
- `/private/tmp/mactools-app-background-swiftui-updates.xml`
- `/private/tmp/mactools-app-background-hitches.xml`
- `/private/tmp/mactools-app-dashboard-user.sample.txt`
- `/private/tmp/mactools-app-dashboard-user.top.txt`
- `/private/tmp/mactools-app-general-visible.sample.txt`
- `/private/tmp/mactools-app-general-visible.top.txt`

Only summarized evidence belongs in the repository. Raw Instruments traces can include process environment data and remain local; the exported table of contents was stripped of its environment section.

## Additional safeguards and lower-priority candidates

- Settings navigation and marketplace projections already suppress unchanged metadata, but individual shortcut/cloud rows and selected plugin content still observe the broad host. Narrow these only where a complete semantic snapshot or explicit revision can preserve dynamic values and closures.
- Settings closes by clearing its content view and releasing its window/navigation coordinator. Do not assume the settings window is permanently retained after close. The observed hidden updates above belonged to the retained menu-bar view tree.
- A plugin settings page refreshes all providers when the app becomes active to restore external/permission freshness. It was not a hotspot in the initial steady samples. Measure activation separately before replacing this behavior; the global Accessibility observer already suppresses equal trust values and uses timer tolerance.
- System Status menu metrics compare full snapshots, but `render` still assigns blocks, intrinsic width, and tooltips on each delivered snapshot. Its metric view invalidates intrinsic size when blocks are assigned. Deduplicating formatted blocks/width is a bounded candidate if traces show a material contribution; no measured attribution to this controller is claimed yet.
- Fan Control SMC calls remain a main-thread I/O risk rather than a demonstrated dominant cost. App Volume's utility scan already suppresses equal results, but its lifetime follows plugin activation because persistent volume routing may need updates without an open panel. A visibility-only stop would change behavior.

## Implemented fixes and verification

### Change boundaries

- App status-icon presentation now compares the complete image source, animation frame, rendering context, and automation count before assigning `NSStatusBarButton.image`. Tooltips and accessibility text remain independently current. Appearance callbacks coalesce, and status-item recreation resets the key. Unused active-plugin observation and repeated length/image-position assignments were removed.
- Window Switcher continues catalog polling, AX discovery, recency tracking, and permission checks. Private catalog changes reconcile an open/pending switcher session without issuing a generic host notification. Permission changes and error clearing still notify the host. An idle catalog no longer sorts session entries merely to discard them.
- Window Layouts resolves built-in and custom action IDs directly for permission membership and managed-shortcut IDs. It no longer constructs and localizes every action definition for each membership query.
- A UI-owned `MenuBarPanelPresentationModel` observes completed panel updates. Retained panel roots subscribe to it instead of the broad host; hidden panels receive no host-driven presentation invalidations and catch up on opening. Hidden geometry reconciliation is skipped. Plugin snapshots, background services, cached component views, scroll state, and detail state retain their lifecycles. Inactive visited tabs inside an otherwise visible popover are not independently gated by this change.
- Duo Status's standalone icon now deduplicates the snapshot and rendering context, coalesces appearance callbacks, observes backing-scale changes, and resets presentation on removal. Its system-status monitoring and host-primary-icon mode are unchanged.

No public PluginKit contract changed. Global action-catalog transaction consolidation remains deferred: shortcut synchronization can invoke plugin callbacks that change live availability, and the second catalog read is not safe to remove solely from a shallow revision comparison. Its final background sampled share is much smaller after the bounded fixes, but the visible-settings sample below still shows intermittent host work. A broad host rewrite, visibility-only shutdown of background services, and unbounded settings-view caches are not part of this implementation.

### Intermediate retest identified a second icon loop

The first implementation cohort, PID 88266 (host built at 23:33:45), included the app icon, Window Switcher, Window Layouts, and panel fixes. `make run` synchronized all 60 plugin packages. With no visible windows, CPU still averaged 88.91% across 15 non-initial observations, with a median of 90.9% and range of 57.8–92.1%.

A 12-second capture recorded 739 main-thread samples. Scheduled host work fell to 24 samples (3.2%), including catalog construction at 10 (1.4%). The app's icon-update method was absent from sampled stacks. However, AppKit status-item replication occupied 466 samples (63.1%), and `DuoStatusMenuBarController.redraw()` occupied 120 (16.2%). The latter came from the plugin's appearance callback and repeatedly assigned `NSStatusBarButton.image`.

Rechecking the original no-window capture also found Duo Status redraw in 32 of 836 samples (3.8%). AppKit's shared replication frames cannot be attributed exclusively to the app's main icon. This additional evidence is why fixing only the initial app-icon finding was insufficient.

### Final background retest

PID 99546 used the host built at 23:38:19. The second `make run` synchronized only the changed Duo Status package and skipped the other 59 unchanged packages. Window probes before and after the CPU and Instruments runs confirmed an existing, inactive Dev process with no on-screen windows and successful WindowServer queries.

Each CPU row below excludes only the initial `top` observation. CPU uses one logical core as 100%; sampling durations differ, and these are short Debug-build observations on the user's active machine, not an energy benchmark.

| No-window cohort | Interval observations | Mean CPU | Median CPU | Range |
| --- | ---: | ---: | ---: | ---: |
| Original PID 12565 | 6 | 90.87% | 96.55% | 61.8–97.3% |
| First implementation PID 88266 | 15 | 88.91% | 90.9% | 57.8–92.1% |
| Including Duo Status fix, PID 99546 | 20 | 13.25% | 4.25% | 2.9–41.5% |

The final CPU capture contains transient peaks and must not be reported as a constant 3–4%. Machine idle CPU varied during the interval. `top` reported approximately 70–71 MB; the separate stack capture reported a physical footprint of 69.3 MB, compared with 152.7 MB in the older, longer-lived cohort that had opened more UI. Those different histories prevent attributing the memory difference to these fixes or claiming a leak was resolved.

A separate 20-second stack capture began at 23:40:12.094 and recorded 1,700 main-thread samples. Scheduled host work accounted for 59 (3.5%), including catalog construction at 23 (1.4%). Neither app/Duo icon rendering nor AppKit status-item replication appeared in sampled stacks. `mach_msg2_trap` accounted for 1,594 samples (93.8%); this includes IPC waits and is not itself a frame-latency measurement. The adjacent 20-second registry log contained two synchronizations, each retaining 52 providers, 255 catalog entries, and zero issues.

A separate 12-second SwiftUI trace exported zero update groups and zero internal update rows, compared with the original hidden-panel capture's 18 transaction groups and 11,785 internal update records. The final process had not yet reproduced the older process's entire visited-window history. This observation and the focused publication tests support the hidden-update fix; they do not establish scroll frame rates or long-session behavior.

### Visible settings, visible panel, and retained-panel checks

General settings was opened through the app's existing URL route, then Codex was activated. Window probes confirmed one visible 1040 x 720 settings window with MacTools inactive throughout the CPU measurement. Eight non-initial observations averaged 8.8% CPU, with a median of 6.95% and a 2.4–18.9% range. A separate eight-second stack capture at 23:44:01.177 contained 610 main-thread samples: scheduled host work 147 (24.1%), including catalog construction 64 (10.5%); no app/Duo icon-update or status-item replication frames were sampled. These separate intervals show intermittent host work remains; the lower CPU capture must not conceal it. Physical footprint during the stack capture was 143.1 MB after opening settings.

The dashboard URL route then opened a 342 x 738 component panel. Probes before and after both measurements confirmed that the panel remained visible and MacTools active, with settings behind it. Eight non-initial CPU observations averaged 4.92%, with a median of 2.65% and range of 2.4–14.2%; `top` reported approximately 157 MB. This is a static visible-panel observation, not confirmed user scrolling.

The subsequent 12-second SwiftUI trace recorded 13 `Transaction` groups with a duration sum of 109.21 ms and maximum of 43.92 ms. Visible panel presentation and the still-open settings window both contributed host-driven transactions. Instruments attributed three hitches to MacTools: 25.00 ms, 16.67 ms, and 8.33 ms. The duration sum is not exclusive CPU time or interaction latency. This proves that the fixes do **not** eliminate every hitch; optimized-build and sustained interaction traces are needed before choosing a wider catalog/publication refactor.

After activating Codex again, probes confirmed that the previously opened panel closed while General settings remained visible. A further 12-second trace recorded one host-driven transaction and 510 internal updates. Their exported descriptions included `SettingsView`, with no matching rows for `ConfiguredMenuBarPanelContent`, `ComponentPanelContent`, `ComponentGridView`, `MenuBarContent`, `FeatureRowView`, or `PanelViewportStack`. This checks the retained panel after actual use, instead of relying solely on the fresh process's no-window result.

### Functional validation

- `make generate` and `make run` completed, including app compilation, plugin package synchronization, and verified development-app installation.
- 173 focused XCTest cases passed for status-item presentation, panel presentation/lifecycle, panel editing and dragging, viewport layout, host component support, Window Switcher, and Window Layouts.
- 24 additional XCTest cases passed for Duo Status icon presentation/artwork, plugin lifecycle, and system monitoring.
- A further 298 cases covered dynamic plugin management/catalog refresh, settings navigation, host activity/actions/navigation, Window Switcher sessions/publication, and icon settings. Initially 296 passed. The metadata-update fixture incorrectly called first-time installation instead of `updatePackage`; an existing chooser-sizing assertion assumed an unsnapped origin, while AppKit differed by half a point on this display. The fixture now uses the update API, and the origin assertion allows one backing pixel while still requiring exact dimensions. Both failed methods passed their targeted rerun. In total, 495 distinct relevant tests passed across the final runs.
- The first Window Layouts custom-command test exposed an incomplete test fixture: deletion requires the host's shortcut-replacement transaction callback. Supplying that callback made the intended permission/removal regression pass; production deletion behavior was preserved.
- `make validate-changelog` and `git diff --check` passed. The installed development app remains PID 99546; no commit, release, or preference-reset operation was performed.

### Local retest artifacts

- `/private/tmp/mactools-performance-regression-summary.json`
- `/private/tmp/mactools-duo-performance-tests-summary.json`
- `/private/tmp/mactools-performance-settings-regression-summary.json`
- `/private/tmp/mactools-performance-regression-recheck-summary.json`
- `/private/tmp/mactools-performance-after-background.top.txt`
- `/private/tmp/mactools-performance-after-background.sample.txt`
- `/private/tmp/mactools-performance-final-background.top.txt`
- `/private/tmp/mactools-performance-final-background.sample.txt`
- `/private/tmp/mactools-performance-final-background.registry.ndjson`
- `/private/tmp/mactools-performance-final-background-swiftui.trace`
- `/private/tmp/mactools-performance-final-background-swiftui-groups.xml`
- `/private/tmp/mactools-performance-final-background-swiftui-updates.xml`
- `/private/tmp/mactools-performance-final-general.top.txt`
- `/private/tmp/mactools-performance-final-general.sample.txt`
- `/private/tmp/mactools-performance-final-panel.top.txt`
- `/private/tmp/mactools-performance-final-panel-swiftui.trace`
- `/private/tmp/mactools-performance-final-panel-hitches.xml`
- `/private/tmp/mactools-performance-final-retained-panel.trace`
- `/private/tmp/mactools-performance-final-retained-panel-updates.xml`

## Primary references

- [Demystify SwiftUI performance (Apple, WWDC23)](https://developer.apple.com/videos/play/wwdc2023/10160/): measure dependencies and update cost before choosing a structural change.
- [Optimize SwiftUI performance with Instruments (Apple, WWDC25)](https://developer.apple.com/videos/play/wwdc2025/306/): distinguish long view updates, repeated update groups, and actual hitches.
- [Minimize Timer Usage (Apple)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html): avoid unnecessary wakeups, use tolerance, and stop timers when their work is no longer needed.
- [Extend App Nap (Apple)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html): reduce work explicitly as demand changes instead of relying solely on system throttling.
