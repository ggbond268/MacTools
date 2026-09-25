# System Status chart choices and sampling review

Reviewed on 2026-09-23. This extends the [collection accuracy review](2026-09-23-system-status-metrics.md). The implementation reuses existing measurements and adds selectable chart presentations and consumer-driven collection. It does not redefine CPU, memory, process, or power accounting.

The follow-up below corrects the initial implementation's GPU temperature shortcut, shared sampling cadence, and historical aggregation. Earlier measurements remain a record of the initial implementation, not a benchmark of the corrected scheduler. The final Memory pressure percentage section supersedes earlier descriptions of level-only pressure charts.

## Available chart metrics

Only Memory expands to a native segmented chart picker in Widget Panel settings. All other charts use their original defaults and have no chart settings disclosure. The memory choice controls both the card and its detail chart. Processes retain their separate maximum-count setting. Row visibility and dragging remain available without opening the row.

| Item | Chart choices | Default | Scope and units |
| --- | --- | --- | --- |
| CPU | Usage | Usage | Host capacity percentage. |
| GPU | Usage | Usage | Selected GPU percentage. |
| Memory | Usage, pressure | Usage | Usage percentage or (wired + physical compressor storage) / physical memory. Pressure estimates use a fixed 0–100% scale and time-weighted statistics; colors retain native normal/warning/critical states. |
| Disk | Transfer rate | Transfer rate | Dual read/write series in bytes per second. |
| Network | Transfer rate | Transfer rate | Dual download/upload series, in bytes per second across active physical interfaces. |
| Battery | Level | Level | Capacity percentage. |

These seven presentations reuse available collectors. Temperature, power, CPU load, used memory, swap, and free disk space remain supporting readings or menu bar values; they do not need separate chart choices. Combined rate charts already show both directions. Menu bar source dependencies are resolved independently of chart selection. Historical records retain optional fields for compatibility and decode without invented values. Missing or uncollected readings produce gaps rather than zeroes or interpolated connections. Older non-memory chart preferences are discarded in favor of fixed defaults; memory preferences and settings backups remain compatible. An explicitly stored but removed memory choice takes precedence over a stale legacy preference and returns to the usage default.

## Upstream comparison

References are pinned to inspected revisions:

- Stats `ef3146cfccc79f4993d6f6a1520b2701106a4957`: [module lifecycle](https://github.com/exelban/stats/blob/ef3146cfccc79f4993d6f6a1520b2701106a4957/Kit/module/module.swift) stops readers when disabled and pauses hidden popup/preview readers. Its [CPU](https://github.com/exelban/stats/blob/ef3146cfccc79f4993d6f6a1520b2701106a4957/Modules/CPU/readers.swift), [RAM](https://github.com/exelban/stats/blob/ef3146cfccc79f4993d6f6a1520b2701106a4957/Modules/RAM/readers.swift), [GPU](https://github.com/exelban/stats/blob/ef3146cfccc79f4993d6f6a1520b2701106a4957/Modules/GPU/reader.swift), and [sensor readers](https://github.com/exelban/stats/blob/ef3146cfccc79f4993d6f6a1520b2701106a4957/Modules/Sensors/readers.swift) offer broader hardware detail. Those additional sensor families need explicit identity and availability handling, rather than relabeling a different measurement.
- Mole `a7fa8dd60f61afdfd81540fc0bf73cc483b98a53`: [CPU](https://github.com/tw93/Mole/blob/a7fa8dd60f61afdfd81540fc0bf73cc483b98a53/cmd/status/metrics_cpu.go) and [memory](https://github.com/tw93/Mole/blob/a7fa8dd60f61afdfd81540fc0bf73cc483b98a53/cmd/status/metrics_memory.go) expose usage/load and memory/swap information. Its [battery collector](https://github.com/tw93/Mole/blob/a7fa8dd60f61afdfd81540fc0bf73cc483b98a53/cmd/status/metrics_battery.go) caches expensive fallback work. These support separate display choices and bounded fallback costs, not interchangeable definitions of pressure, watts, and percentages.
- Vorssaint `58b93d55f027d7c7532f4873f6db589e6810d2ab`: [SystemMonitor](https://github.com/vorssaint/vorssaint-utils/blob/58b93d55f027d7c7532f4873f6db589e6810d2ab/Sources/Vorssaint/Services/SystemMonitor/SystemMonitor.swift) derives a union of visible surfaces, menu bar consumers, and alerts, and lazily initializes SMC. Its [sampling policy](https://github.com/vorssaint/vorssaint-utils/blob/58b93d55f027d7c7532f4873f6db589e6810d2ab/Sources/Vorssaint/Services/Metrics/MonitorSamplingPolicy.swift) separates source cadences. MacTools follows the same demand-union principle while preserving its existing enabled-history contract and sampling intervals.

Apple definitions and hardware limitations remain documented in the collection review. In particular, [Activity Monitor's memory-pressure explanation](https://support.apple.com/en-au/guide/activity-monitor/actmntr1004/mac) does not equate pressure with used-memory percentage, and [XNU's pressure interface](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c) returns discrete flags. The later percentage implementation below uses a separately defined constrained-memory estimate; it does not convert these native flags into percentages.

## Candidates requiring additional work

These remain outside this implementation, rather than appearing as options with guessed values:

| Candidate | Work required before exposing it |
| --- | --- |
| CPU per-core/cluster load and CPU/GPU frequencies | Add dedicated readers and define aggregation and hardware coverage. Do not treat host CPU usage as an individual-core measurement. |
| GPU, SoC, and whole-machine power | Identify separate energy channels and domains. CPU watts, battery watts, adapter rating, and relative Energy Impact are different quantities. |
| Fan speed and individual sensor temperatures | Add stable sensor selection and availability handling, including machines without fans. |
| Per-disk capacity, health, and temperature | Add disk identity/selection and supported SMART access. The current aggregate I/O and home-volume capacity cannot imply per-disk health. |
| Cumulative network traffic and latency | Define reset/session semantics for totals; latency requires an explicit target and a separate bounded active probe. |

Existing battery health, cycle count, time remaining, and adapter rating remain supporting information. They are not added as dynamic chart choices in this phase.

## Demand and lifecycle

One shared collector combines selected menu bar values, enabled chart history sources, supporting values on visible cards, and independently visible detail windows. Repeated values and multiple consumers union their source dependencies rather than creating timers. Opening a card can legitimately request its visible temperature, load, or footnote values in addition to its selected chart.

When panels are closed, only enabled chart sources and selected menu bar values remain active. Enabled charts intentionally keep background history: fast sources use the existing 30-second cadence in background mode, slow sources use five minutes. Visible menu bar values retain their existing faster cadence. Foreground fast values and processes refresh about every three seconds; foreground slow sources retain their 15-second interval. Slow-only demand sleeps at the slow interval instead of waking at the fast interval. Existing history retention and persistence limits remain bounded.

Process lists have no historical chart, so hidden lists stop scanning. Process-only demand does not load or append chart history. With no consumer demand, the polling task exits. SMC and IOReport resources are lazy and released when no longer requested. Unneeded in-flight process and battery-health commands are canceled through their owned process groups. Battery-health fallback work remains cached and coalesced.

Stopping or reconfiguring collection rejects results from an older generation, including manual refresh and history loading. Network/disk counter baselines and CPU power state reset when their source is disabled. Re-enabling starts a fresh baseline; an unavailable initial sample is preferable to a rate across an unobserved interval. CPU power still retains a valid slow-provider reading for at most 60 seconds while enabled.

## Verification and observations

The six related XCTest classes passed 50 tests with no failures or runtime warnings. Coverage includes preference migration/backup, units and signs, unavailable history and chart gaps, the consumer-demand union, collector shutdown, existing process accounting, pressure mapping, power fallback behavior, and command cancellation. After the final lifecycle adjustment, all 16 demand/plugin tests passed again, including stopping an in-flight manual refresh before subsequent slow/process collection.

Offscreen native AppKit/SwiftUI renders checked expanded settings, all six alternative cards, and signed battery-power detail charts at 420- and 620-point widths in light and dark appearance. No application settings or synthetic system load were changed for these checks.

A read-only Debug probe on this M1 Max compared the exact pre-change sampler with the selective sampler. Each row below is ten warm fast-plus-slow collection cycles after an untimed warmup; it excludes process scans, history writes, and UI rendering. The full-reader timing varies, so these observations do not establish a universal speedup:

| Demand | Mean time per collection cycle |
| --- | --- |
| Previous full collection | 14.211 ms |
| Current full collection | 18.459 ms, with a 39.203 ms outlier |
| CPU usage only | 0.00257 ms |
| CPU temperature only, cache hit | 0.00211 ms |
| Memory pressure only | 0.00308 ms |

The selective paths avoid unrelated system queries; the temperature number measures a cache hit, not native sensor I/O. No claim is made about whole-app CPU percentage or battery life. The no-demand path returned empty data, and both network and disk correctly returned an unavailable first rate after re-enabling. Five CPU-power enable/disable cycles retained a constant Mach-port count of 50. A separate 22-sample trace at three-second intervals returned CPU usage and CPU power after the initial baseline; watts ranged from approximately 2.16 to 11.78 with bounded reuse between provider updates. This confirms collection and lifecycle behavior on this machine, not calibration or support on every Mac.

## Follow-up confirmation and corrections

The review reproduced three historical-data defects and confirmed two collection issues against the reference implementations:

1. Stats reads `Temperature(C)` from GPU registry statistics before using hardware-specific SMC fallbacks. The temperature-only shortcut in MacTools skipped that native source. Both GPU modes now inspect the same devices, preserve device selection, and use the fallback only when needed. The temperature-only path does not expose an unrequested utilization value.
2. Live history previously kept only the last observation in each old minute. A critical-to-normal transition therefore lost its already-observed critical peak. Shared compaction now retains the actual peak observation and the last observation, with their original timestamps. Availability and collection-session changes split compaction groups. Persistence batches the observations collected since the previous write and compacts them once, so a transient peak is not lost merely because it occurred between disk writes. The 24-hour retention and 8,640-point hard limit remain.
3. Scalar statistics previously averaged samples with equal weights even though foreground, background, and archived samples have different spacing. That is a valid *sample mean*: [Prometheus explicitly documents equal weighting](https://prometheus.io/docs/prometheus/latest/querying/functions/#aggregation_over_time). It is unsuitable for interpreting this UI's selected time range as a time average. The initial correction followed linear integration described by [TimescaleDB Toolkit](https://github.com/timescale/timescaledb-toolkit/blob/main/docs/time_weighted_average.md). The counter-interval correction below supersedes that method for CPU and throughput; linear interpolation remains appropriate only for gauge estimates.
4. A stopped collector's in-memory gap marker did not survive restart. Each collection session now has an optional persisted identifier. New history cannot connect to an older session, including legacy records without identifiers. Scalar/rate paths, pressure intervals, and hover lookup respect the boundary. Existing archives remain readable; gaps or peaks already lost by older versions cannot be reconstructed.
5. The global menu-bar flag accelerated every enabled source. The replacement plan assigns deadlines to individual data sources, inspired by Vorssaint's separate sampling cadences. One cancellable loop sleeps until the next deadline; each batch requests only due sources and merges only their fields into the snapshot. CPU counters are retained when a temperature-only batch runs. GPU usage and temperature share a cadence when both are enabled because they must describe the same selected device and already share one registry enumeration. History and process scheduling do not create additional polling loops.

The full related suite passed 54 tests after these corrections. Final focused runs then passed all 22 demand/plugin/chart tests and all five chart tests after preserving the first observation at a compacted session boundary. New coverage verifies native GPU temperature and fallback behavior, source-specific deadlines and snapshot merging, density-independent time weighting with gaps, and pressure peaks/session boundaries through actual temporary-file persistence and reload. Offscreen light/dark renders checked that chart gaps, signed power, statistics, and layout remain readable.

A read-only eight-second native probe enabled all default background charts and only disk read/write values in the menu bar. Its first batch collected the initial fast and slow sources; both subsequent batches collected disk activity alone. GPU and battery were sampled once, and no process scan occurred. A separate ten-sample, three-second native trace continued to read CPU usage and pressure; CPU power became available after the provider's initial update and retained approximately 2.64-6.62 W readings between updates. These checks validate demand and recovery behavior; they do not measure whole-app energy consumption or establish cross-device sensor calibration.

## Core chart option refinement

The settings now expose at most three chart options per item through the same native segmented controls used for menu bar appearance. Network keeps its combined rate chart and has no redundant one-option disclosure. Existing visibility buttons, whole-row dragging, and unhighlighted row backgrounds are preserved. This is a presentation simplification: menu bar readings retain their original source dependencies, and the collector cadence is unchanged.

Pressure was checked again against Apple and Stats. [XNU exports pressure as dispatch flags](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c), while [Apple’s memory_pressure utility](https://github.com/apple-oss-distributions/system_cmds/blob/main/memory_pressure/memory_pressure.c) reports a separate system-wide free-memory percentage. Inverting that percentage would be a separate estimate, not a documented Activity Monitor pressure percentage. The initial implementation retained native pressure levels. The subsequent percentage implementation below preserves those levels for colors and introduces an independent estimate rather than converting levels or relabeling memory usage.

The refinement passed all 26 focused chart, demand, pressure, and plugin tests. Coverage verifies fallback from removed chart preferences without losing other settings, retained menu bar dependencies, and both directions of rate charts. Offscreen native renders at 420 and 620 points checked the expanded controls in light and dark appearances; all choices remained visible. Changelog validation and whitespace checks also passed.

## Memory pressure percentage

Following the request for a continuous percentage, the chart now uses `(wire_count + compressor_page_count) * native_page_size / physical_memory * 100`. This is the constrained-memory proxy explicitly documented in [MacPulse's reader](https://github.com/vluncasu/macpulse/blob/d54596b0b7c5c2ec9bec43c00886fe327aab275c/MacPulse/Metrics/MemoryReader.swift#L38-L47). Apple defines `compressor_page_count` as the physical pages holding compressed data in [vm_statistics64](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h). Lifetime compression events, the original uncompressed page count, and swap usage are excluded. This quantifies a specific memory share; it is not an implementation of Activity Monitor's undocumented continuous pressure graph and does not independently capture swap rate or thrashing.

The setting and chart title say Pressure. The detail view explains the estimate formula, and native pressure levels independently determine colors and the current system-pressure label. No percentage thresholds manufacture warning or critical states. Charts use a fixed 0–100% domain, actual observation timestamps, percentage hover values, and the existing time-weighted average. Missing percentages remain gaps even when a native pressure level is available; missing native levels use neutral colors without suppressing a valid estimate.

The sampler reads VM statistics once per due memory batch, shared with memory usage when both are requested. Pressure-only sampling reads just VM statistics, page size, physical memory, and the native pressure flag. It does not request swap, scan processes, launch commands, or query unrelated sensors. Existing usage accounting and per-source deadlines remain unchanged. Invalid page size or total memory leaves the estimate unavailable instead of reporting zero.

An optional history field stores percentages separately from native levels. Legacy level-only records remain readable but cannot produce percentage values. Compaction retains percentage extrema, native-state transitions, availability boundaries, and collection boundaries; downsampling retains observed extrema and severe native states with their own percentages and timestamps. Gaps removed by downsampling still break the path. Existing retention and sample-count limits apply.

Verification passed all 51 focused pressure, chart, demand, plugin, and sampler tests. Fixtures exercise 4 KiB and 16 KiB pages, current versus lifetime/uncompressed compressor counters, independent usage and native states, missing inputs, source merging/shutdown, percentage extrema, legacy archives, and gaps. Native light/dark renders checked 420- and 620-point settings and detail layouts.

A read-only Debug probe on this 64 GiB M1 Max ran 100 warmed calls per demand mode, including actor-call overhead. Pressure-only averaged 0.01965 ms, usage-only 0.01538 ms, and combined usage plus pressure 0.01984 ms. Disabled demand returned no memory values. Pressure-only returned no usage or swap; usage-only returned no percentage or native pressure flag. The percentage was 21.4957%, matching an independent calculation from 285,688 wired pages, 615,907 compressor pages, and a 16,384-byte native page size; the native pressure level remained Normal. This is a local collector observation, not a whole-app energy benchmark. No process or workload was created to force memory pressure.

The final ten pressure/chart tests passed again after retaining native-state transition endpoints during downsampling. Essential state transitions may exceed the approximate 120-value rendering budget, bounded by the existing history limit, so a brief critical observation cannot color a later normal interval. Changelog validation and whitespace checks passed.

## Memory-only chart selection

The final settings refinement retains Usage and Pressure only for Memory. Other charts use their original defaults, and their obsolete selectors, rendering branches, and labels have been removed. Decoding discards previous non-memory choices while preserving the memory preference and backup compatibility. The title is now Pressure in all supported locales; the percentage formula, native status colors, menu bar choices, and supporting sensor readings remain unchanged.

All 27 focused chart, demand, pressure, and plugin tests passed with no runtime warnings. Offscreen native previews at 420 and 620 points confirmed that only Memory and Processes disclose settings in light and dark appearances. The default CPU/GPU usage, disk/network rate, battery-level, and memory-pressure charts rendered correctly. Changelog validation and whitespace checks passed.

## Panel reopening and snapshot retention

The previous collector kept the complete snapshot across panel closure and sampled all fast sources every 30 seconds, with slow sources and processes every five minutes in the background. The demand-based implementation stopped unnecessary work, but also cleared paused fields from the displayed snapshot. Reopening therefore exposed missing secondary readings and the process placeholder. In addition, a single final publication made completed fast readings wait for slow collection and process enumeration.

Sampling demand and presentation retention are separate. Closing a surface preserves its latest in-memory snapshot while its sources follow the demand policy. Reopening immediately displays that snapshot until the next completed reading replaces it. There is no display expiration timer or separate timestamp map; retaining one bounded snapshot does not accumulate additional history or keep collectors running. Reopening starts newly requested or overdue sources immediately; already-recent sources keep their sampling timestamps. The shorter foreground interval advances their next deadline without forcing a redundant counter read. GPU usage and temperature still refresh together whenever either is due, including when one is newly enabled. Disabling a source everywhere or stopping the plugin removes its retained values. Cleanup also runs when a visibility change leaves the active sampling plan unchanged, such as hiding a CPU card while its usage remains enabled in the menu bar. Continuously active sources keep their existing sampling cadence. Retention adds no polling, process scans, or sensor reads. A completed unavailable reading still replaces the previous result. CPU power's collector-level validity limit remains independent of this presentation policy.

Fast, slow, and process batches publish separately after their cancellation and generation checks. Source deadlines are recorded when each batch completes. This restores incremental presentation without allowing results from a stopped generation to update the UI. History construction explicitly excludes paused display-only fields, so retaining a value for presentation cannot manufacture a new observation. Initial startup still requires a real sample; the implementation does not synthesize zeroes or restore historical values as current measurements. Chart history remains a separate, potentially downsampled record without process rows or complete device metadata, so it is not used to reconstruct live snapshots.

All 25 focused demand, plugin, chart, and CPU-power validity tests passed with no runtime warnings. Coverage verifies snapshot reuse after a simulated one-hour pause, no hidden process scans, no retained fields in new background history, and publication before deliberately blocked slow/process readers finish. It also checks cleanup when collection demand is unchanged, plugin shutdown, and replacement by an unavailable reading. The earlier one-minute presentation policy and its expiry-specific state have been removed. Changelog validation and whitespace checks passed.

A read-only native Debug probe on this M1 Max observed CPU publication at about 299 ms, disk capacity at 430 ms, and process rows at 541 ms during cold collection. After closing and reopening, CPU, capacity, and process rows were immediately retained and remained present until explicit shutdown. Hidden process and CPU-power demand were both false. These are local collector observations, not a frame-rate or whole-app energy benchmark; the probe changed no application preferences and created no synthetic workload.

## Counter intervals and frozen CPU power (2026-09-24)

CPU utilization and disk/network throughput describe the interval between two counter reads. Applying trapezoidal interpolation to those interval averages was incorrect when cadence changed: three seconds at 100% followed by thirty seconds at 0% produced 50% instead of 9.09%. The sampler now attaches monotonic elapsed durations and wall-clock endpoints to these readings. History records an interval only when that source was actually sampled; process-only batches add no metric history. Snapshot merging preserves interval identity when unrelated sources refresh.

Minute compaction retains each source's weighted total, covered duration, minimum, and maximum on one retained point. CPU weights use total native CPU ticks, preserving the ratio of accumulated busy time to total CPU time even when tick advancement differs from wall time. Throughput weights use elapsed seconds. Repeated compaction does not double-count the points retained for pressure extrema. Chart averages divide weighted totals by their corresponding weights; clipping at the selected time range assumes the interval's measured mean within the overlapping portion. Gaps add no weight. Gauge averages keep their existing interpolation. Old archives remain readable and visible, but records without measurement intervals do not supply counter-rate averages: reconstructing their missing intervals would invent timing information. All metadata is optional, so the existing archive schema remains compatible.

The power investigation used the current native reader on an M1 Max running macOS 27.0 (26A428). All 61 samples over approximately 126 seconds returned the same CPU energy, 2,539,518.261 J, and the same source timestamp. The source was already about 15 minutes old when the probe started. Three fresh subscriptions returned the same data as a retained subscription. CPU-specific SMC keys PC0C, PCAM, PCPC, PCTR, PCPT, PCPR, and PC0R returned no values; readable PSTR and PHPC are not substituted for CPU-only power. This is direct evidence of a stalled native energy source in this run, independent of the panel lifecycle. It resembles the separately reported [macmon issue 76](https://github.com/vladkens/macmon/issues/76) on macOS 27, without establishing identical behavior on every chip or OS build.

The collector cannot infer current CPU watts from an unchanged stale counter. The bounded valid-reading retention and unavailable result remain, without adding expensive retries, privileged background tools, or a whole-system-power substitution.

The final focused run passed all 49 chart, demand, sampler, and plugin tests with no runtime warnings. Six additional pressure/demand checks passed before the final CPU tick-weight refinement. Coverage includes unequal collection cadences, retained snapshots, collection gaps, native CPU tick weights, and incremental compaction followed by file reload. A native probe also confirmed valid CPU, network, and disk interval metadata at one- and three-second cadences, with unavailable initial network/disk rates preserved. Changelog validation and whitespace checks passed.
