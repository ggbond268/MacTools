# Window Switcher Performance Plan and Implementation

Date: 2026-09-20

Baseline: `35a1d98f`. This work follows the [live Energy Impact investigation](2026-09-20-performance-follow-up-audit.md#follow-up-current-energy-impact-remains-high).

The objective is to reduce repeated background discovery and main-thread publication while preserving window coverage, recent-use ordering, shortcuts, and action validation. The earlier profile attributed 730 ms of 1,149 ms of sampled Running work to Window Switcher. That is CPU sample weight, not an energy share or predicted saving.

## Confirmed gaps in MacTools

The file locations in this table refer to the baseline revision, before the worker was extracted into its own file.

| Priority | Baseline behavior | Consequence |
| --- | --- | --- |
| High | `WindowSwitcherAppCatalog.DiscoveryEnvironment.applications` rereads every application's dynamic properties and identity on each refresh (`WindowSwitcherAppCatalog.swift:589`). | Main-thread LaunchServices work repeats despite unchanged applications; confirmed by the live profile. |
| High | A repeating one-second timer, workspace events, and AX invalidations all enter the same full refresh (`:649`, `:686`). The worker callback discards the PID/window/event context (`:514`, `:809`). | A single title or focus change can cause unrelated applications and all-Spaces records to be rescanned. |
| High | Each application completion, the refresh loop, and the all-Spaces completion rebuild the combined publication (`:775`, `:785`, `:866`). | Repeated full-list work on main; 105 ms appeared under publication in the earlier trace. |
| Correctness prerequisite | Notification registration results are ignored; windows enter `observedWindows` before successful registration (`:507–529`). Move/resize notifications are absent. | Removing polling now would leave subscription failures and geometry changes without dependable recovery. |
| Correctness prerequisite | `WindowSwitcherPlugin.beginSession` only refreshes when the cache is empty or initial discovery is incomplete (`WindowSwitcherPlugin.swift:643`). | Lower background scan frequency requires an invocation reconciliation path even for a nonempty cache. |
| Medium | `freshWindowRecordSnapshot` checks task completion every ten milliseconds (`WindowSwitcherWindowRecords.swift:262`). | Avoidable wakeups while waiting for the system query. The existing timeout, late-result guards, and in-flight cap must remain. |

The issue is the amount and scope of repeated work. Merely moving all of it off main can improve responsiveness while leaving CPU, system-service activity, and energy largely unchanged. Merely changing the timer from one to several seconds also extends stale-state windows without repairing notification coverage.

## Implemented design

### Application inventory

`WindowSwitcherApplicationInventory` owns application snapshots and KVO lifetimes. Unchanged process-list reconciliation reuses cached properties. Process equality, PID changes, and explicit generations distinguish replaced applications even when launch dates are unavailable. Static identity and presentation data are cached; policy and launch-completion changes invalidate metadata. Active/hidden state follows application changes. Helper applications remain in the inventory without eagerly loading their icons.

The inventory is stopped with the catalog, and late callbacks from removed or previous-lifetime entries cannot update a replacement. Periodic and invocation reconciliation still compare the running-application list to recover missed list notifications.

### Scoped discovery and bounded work

AX callbacks retain the source PID, worker lifetime, and event kind. A 200 ms coalescing window merges affected hosts. Focus/title events avoid an unrelated WindowServer query; creation, destruction, minimization, movement, and resizing also reconcile window records. Helpers route through their host while retaining their actual AX owner for actions.

Pending invalidations are distinct from active scans. Events arriving during a read schedule a follow-up instead of being dropped. At most four host discovery jobs run at once; each job keeps its process worker's serial AX access and reads associated helpers sequentially. Stop/restart does not free a job's slot until its physical read returns. Activation and validation retain their existing process-worker ordering.

Drag-time invalidations remain pending until tracking ends. Application, Space, display-topology, wake, and session events request the appropriate reconciliation. Sleep and inactive-session notifications suspend background scheduling; resumption requests a full refresh.

A five-second fallback with one-second timer tolerance replaces the one-second full scan. It remains necessary for unsupported or omitted notifications. This is a conservative recovery interval, not a claim that AX events are complete or that background work is zero.

### Subscription recovery

Notification registration is recorded only after success or an already-registered response. Unsupported notifications rely on reconciliation; transient failures retry on subsequent scans with bounded exponential backoff. An invalid observer is replaced. Window movement and resizing are included so display-scoped listings can update without waiting for the fallback.

### Publication and invocation

Discovery completions update stored process snapshots. Publication is coalesced over a 16 ms window, with a UI notification only when entries, focus, or readiness change. Healthy results can publish while another application remains slow.

Every invocation requests fresh discovery, including when the cache is nonempty. The plugin retains shortcut steps and a quick release until the invocation's reconciliation is ready, then selects from that snapshot. Session generations reject late work. Existing discovery deadlines, permission checks, helper ownership, cross-Space evidence rules, and activation validation remain in force.

Window enumeration and waiting remain off the main thread; publication stays on the main actor. Invocation latency must be measured alongside idle CPU because correctness cannot be traded for a faster commit from an outdated list.

### Window-record completion

`WindowSwitcherWindowRecords` delivers results through continuations and one deadline per shared query. A cancelled waiter does not cancel another caller's wait. Stop and timeout resume waiters immediately; a late system result cannot overwrite a newer generation. The two-query physical limit remains occupied until the actual system calls return. No ten-millisecond completion polling remains in this reader.

Preview behavior is unchanged: selected-window capture, existing debounce, count/lifetime limits, and obsolete-result rejection remain. Preview warming and broader capture are outside this change.

## Validation

Tests cover cached inventory reads, process replacement and PID changes, stale observer callbacks, subscription failures, coalesced/scoped invalidation, drag deferral, events arriving during a scan, physical concurrency across restart, unchanged UI publication, fresh nonempty invocation, quick-release navigation, shared-query cancellation, timeout, stop, and late results. Existing window/action, all-Spaces, helper ownership, ordering, permission, preview, and overlay tests remain part of the regression run.

Runtime validation should separate no-window idle from invocation and visible interaction. Compare the same plugin set, window population, build configuration, and other running application instances. Record CPU, wakeups, physical footprint, main-thread work, and invocation readiness together. Other measured host/shortcut work is not eliminated by this window-focused change.

### Automated and build results

- All 331 Window Switcher tests passed in a serial run across 20 test classes, with no failures or skipped tests. The result bundle is `/private/tmp/mactools-window-optimization-final.xcresult`.
- All 269 repository script tests passed. Changelog validation and `git diff --check` passed after the final fragment update.
- `make generate`, `make build-plugin PLUGIN=WindowSwitcher`, and the Debug app build/install succeeded. The installed Dev process loaded the updated dynamic `WindowSwitcher.bundle`; no plugin activation error was found in its startup log.
- One existing overlay lifecycle test now waits for the test host's actual foreground activation before simulating selection. Window visibility alone precedes activation. The existing protection against an unrelated foreground change remains unchanged.

The tests cover deterministic state and action behavior; they do not establish real-machine scrolling frame rate or end-to-end shortcut latency.

### Installed Dev observation

The baseline Dev process was PID 36591. After installing the rebuilt Debug app and only the changed Window Switcher package, Dev was PID 26936. The loaded bundle's SHA-256 matched the build product. Existing preferences and other installed plugin packages were retained. WindowServer probes found no on-screen Dev windows at the start of either sample. No build, test run, or profiler ran during these intervals.

Each observation used `proc_pid_rusage(RUSAGE_INFO_V4)` for approximately 40 seconds at two-second intervals, converting CPU ticks with the machine's `mach_timebase_info`. CPU 100% denotes one core.

| Process and interval | Mean CPU | Two-second CPU range | Interrupt wakeups/s | Physical footprint |
| --- | ---: | ---: | ---: | ---: |
| Dev before | 9.97% | 4.01–27.77% | 14.67 | 239.78–243.35 MiB |
| Dev after | 3.50% | 0.27–17.55% | 11.25 | 106.08–108.27 MiB |
| Separate Nightly, before interval | 97.14% | 90.93–99.88% | 38.92 | 271.45–272.69 MiB |
| Separate Nightly, after interval | 97.30% | 96.28–98.01% | 36.25 | 272.74–272.80 MiB |

The observed Dev CPU mean was about 65% lower and interrupt wakeups about 23% lower. These are short live-machine observations, not replayed workloads or a promised steady-state reduction. The Dev restart changes retained views, caches, and uptime; the footprint difference must not be attributed to this patch or described as a leak fix. Nightly remained running and was measured separately. No watts or Activity Monitor Energy Impact score was measured.

A subsequent 20-second Time Profiler capture contained 1,266 ms of Running sample weight, including 1,123 ms on main. Window Switcher accounted for 188 ms (14.85%), compared with 730 ms in the earlier investigation's separate 20-second trace. Its inventory reconciliation remained visible at 105 ms inclusive; broad per-application property reads and repeated publication no longer dominated the capture. These samples support reduced discovery work, but their ratios are not energy shares.

The largest remaining group was scheduled `PluginHost` work: 903 ms (71.33%), including descriptor/localization construction, action registry synchronization, legacy migration reads, and unchanged shortcut callbacks. Host work was much higher in this trace than the earlier trace, illustrating why short total-CPU comparisons need qualification. It remains a separate optimization candidate; this patch does not change host registry or shortcut semantics.

Artifacts: `/private/tmp/mactools-window-before-clean.ndjson`, `/private/tmp/mactools-window-after-clean.ndjson`, `/private/tmp/mactools-window-comparison.json`, the corresponding visibility JSON files, and `/private/tmp/mactools-window-after-idle.trace`, `.xml`, and `-summary.json`. The earlier `mactools-window-before-rusage.ndjson` sample overlapped test/build work and is excluded from this comparison.

Real keyboard invocation and visible scrolling still require interactive confirmation. External run links intentionally do not support these foreground window-switching actions; this validation does not bypass that restriction or infer UI smoothness from idle CPU.
