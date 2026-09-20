# Current Dev Performance Audit

Date: 2026-09-20

Scope: inspect the current Dev process and current source, without comparing against another application version. This follow-up is diagnostic; it makes no production-code changes.

## Runtime and source boundary

The sampled process is PID 19401, MacTools Dev 1.3.1 (70), launched at 16:24:50. Its installed debug library was built at 16:24:15. It includes the first host performance batch described in [the host plan](2026-09-20-plugin-host-performance-plan.md). The shared workspace also contains subsequent panel-presentation edits that are not in this installed build. Findings below identify source paths that remain present in both the running host/plugin build and current source; later UI changes are not claimed to have been measured.

WindowServer probes before and after each collection found no visible Dev windows. This is a background workload on an actively used machine, not a controlled user-input replay or a foreground scrolling benchmark. No app restart, plugin disablement, preference change, or power assertion change was performed during this audit.

## Current process observations

Two independent 40-second windows were collected without Time Profiler or the memory inspection attached. One CPU core equals 100%.

| Metric | First window | Second window |
| --- | ---: | ---: |
| Mean CPU | 5.11% | 2.32% |
| Interrupt wakeups/second | 31.22 | 11.25 |
| Physical footprint range | 185.28–185.42 MiB | 178.52–178.61 MiB |
| CPU energy increment | Not collected | 1.4525 J |
| Mean attributed CPU power | Not collected | 36.23 mW |

The first window's two-second CPU intervals ranged from 0.32% to 12.23%, and disk-read/write counters did not advance. The physical footprint stayed nearly flat within each window. This does not prove the absence of a leak over longer workloads, but there is no growing-memory failure in these samples.

The second window uses `proc_pid_rusage(RUSAGE_INFO_V6)` and the delta of `ri_energy_nj`, divided by elapsed monotonic time. The local SDK supplies the structure layout; process start time is checked against PID reuse. Apple's [task resource accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) populates this field from task power accounting, and [recount](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/recount.c) attributes CPU energy to task/thread CPU work. This is a kernel-accounted CPU energy observation, not Activity Monitor's Energy Impact score, a wall-power reading, or complete app-attributable GPU/display/system-service consumption. Performance cores account for approximately 94.49% of this sampled CPU energy; that alone does not justify changing QoS or actor isolation.

## CPU attribution

A separate nominal 30-second Time Profiler recording contains 583 ms of Running sample weight, including 423 ms on the main thread (72.56%). Exclusive groups assign host-triggered plugin calls to the host first:

| Group | Running sample weight | Share |
| --- | ---: | ---: |
| Scheduled PluginHost updates | 244 ms | 41.85% |
| Window Switcher | 210 ms | 36.02% |
| App Volume | 65 ms | 11.15% |
| Activity Bar | 18 ms | 3.09% |
| System Status | 14 ms | 2.40% |
| Other / unresolved | 32 ms | 5.49% |

These are sampled CPU weights, not percentages of energy or guaranteed savings. The trace supports reducing main-thread maintenance work. It does not establish a foreground SwiftUI rendering bottleneck.

## Important remaining work

### 1. Correct application-inventory hashing

`WindowSwitcherApplicationInventory.Source.identity` currently wraps `NSRunningApplication` directly in `AnyHashable`. Reconciliation constructs a set and repeatedly queries a dictionary using these keys. In this trace, reconciliation accounts for 144 ms; `AnyHashable` equality appears in 113 ms of that inclusive weight. The five-second fallback reaches this work even without a visible switcher.

A separate read-only diagnostic found 149 running application objects, 149 distinct application identities, and only one hash value across the keys. Thus all keys collide on this system. Twenty set constructions took 35.40 ms with the existing keys versus 0.44 ms with precomputed typed PID keys. This microbenchmark isolates key behavior; it excludes PID retrieval and lifecycle validation and is not an estimate of whole-app savings.

Recommended fix: use an explicit application-identity key whose hash incorporates the captured PID, while equality retains application-lifetime identity. Alternatively, index by PID and validate the existing application's identity after lookup. A PID alone is insufficient because it can be reused; pointer identity alone is insufficient when wrappers are recreated. Preserve replacement detection, observer cleanup, stale-callback generations, helper ownership, and the existing reconciliation/invocation timing. Cover equal wrappers, hash collisions, PID reuse, removal/reappearance, and deferred notification delivery. This is the most concrete, narrowly scoped remaining optimization.

### 2. Consolidate host update projections and reduce unnecessary broad work

`schedulePluginStateChangeRebuild()` still performs a derived-state rebuild followed by shortcut synchronization. Both phases build the complete action-shortcut presentation: 45 ms under the registry/rebuild path and 46 ms under shortcut synchronization, totaling 91 ms inclusively in this trace. Action availability is queried during presentation construction. Physical Clean Mode's exit-shortcut availability check re-enters the host's full shortcut resolver, accounting for 18 ms within that presentation work.

Recommended sequence:

1. Define one completed-update boundary and build the action-shortcut presentation after registration/conflict state settles. Preserve standalone rebuild/shortcut entry points and the ordering of catalog-consumer callbacks.
2. Reuse validated shortcut inputs within that synchronous update, including resolver calls made by availability providers. Physical Clean Mode must retain its valid-exit-shortcut check and execution-time validation.
3. Compare equatable presentation values before publication and record dirty plugin IDs/notification causes. The asynchronous sampled stack cannot identify which plugin originally requested the update.
4. Only then consider per-provider structural snapshots. Ordinary state changes can add/remove actions or change defaults, so dirty providers must still be reread; language, replacement, failure isolation, import/reset, and cross-provider dependencies require explicit invalidation.

Reducing these main-thread traversals should be evaluated for both background cost and interaction latency. Increasing the debounce delay, skipping live availability, or publishing only by matching IDs/counts is not an equivalent safe fix.

### 3. Replace repeated audio discovery with property-driven reconciliation

`AudioApplicationScanLoop` runs every second. Each pass obtains the Core Audio process list and queries output activity for all entries, even when the published snapshot is unchanged. The current snapshot query accounts for 63 ms, including 42 ms under running-output property reads. The existing equality guard avoids notifications but does not avoid those IPC queries.

Use Core Audio property listeners for process-list changes, each process's output-running state, and the default output device, with coalesced reconciliation and a conservative fallback. Handle process removal, listener-registration failure, audio-service restart, and device changes. Keep active audio control running while panels are hidden; do not tie control correctness to UI visibility. This is a secondary optimization compared with the first two items, and should be independently tested.

## Memory priority

`vmmap -summary` reported a 185.3 MiB physical footprint and a 222.8 MiB lifetime peak. Allocated malloc objects accounted for approximately 76.7 MiB; dirty heap pages also included approximately 44.9 MiB of allocator fragmentation/free capacity. CoreAnimation and IOSurface regions were approximately 25.6 MiB and 14.5 MiB. These categories are not an additive attribution of individual plugin ownership. Shared library mappings and virtual address reservations must not be described as private app memory.

Source inspection shows bounded clipboard preview caching (32 MiB/eight entries), bounded window previews (eight fitted images with 30-second expiry), and plugin-keyed view caches with lifecycle trimming. No unbounded cache or growing-memory failure is established here. Reduce repeated temporary collection construction first. If retained UI memory becomes a problem, compare heap generations around repeatable panel open/close cycles and identify owners before adding memory-pressure cleanup or cache budgets. Destroying every retained view when hidden could worsen reopen latency and reset local state.

## Artifacts

- `/private/tmp/mactools-current-dev-rusage.ndjson` and `-rusage-summary.json`
- `/private/tmp/mactools-current-dev-energy.ndjson` and `-energy-summary.json`
- `/private/tmp/mactools-current-dev.trace`, `.xml`, and `-trace-summary.json`
- `/private/tmp/mactools-current-dev-vmmap.txt`
- `/private/tmp/mactools-application-identity-probe.swift` and `.json`
- The corresponding `mactools-current-dev-*-visibility.json` files

All observations describe the current Dev process at collection time. No Nightly comparison or projected power-savings percentage is used to rank these remaining changes.

The three prioritized changes were subsequently implemented and validated in the [background maintenance optimization record](2026-09-20-background-maintenance-optimization.md), including the Core Audio notification behavior discovered by real playback probes and the limits of post-change CPU/memory measurements.
