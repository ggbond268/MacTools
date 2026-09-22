# Background Maintenance Optimization

Date: 2026-09-20

This implements the three bounded follow-ups from the [current Dev audit](2026-09-20-current-dev-performance-audit.md), in priority order. The audit remains a record of its original process and source boundary. No plugin is disabled, no user preference is changed, and no UI refresh or safety check is removed to improve measurements.

## Application inventory identity

`WindowSwitcherApplicationIdentity` hashes the captured PID while comparing both PID and application-object equality. It avoids the shared `NSRunningApplication` hash observed on this machine without treating PID reuse as the same lifetime or requiring pointer identity for equivalent wrappers. Inventory reconciliation, property observation, generation checks, and window discovery timing remain intact.

Tests cover equivalent wrappers, PID reuse, shared NSObject hashes, replacement/removal, unchanged property snapshots, and deferred callbacks. The first focused inventory/catalog run passed 18 tests.

## Completed host projection

The sixteen existing rebuild-plus-shortcut call sites now request shortcut synchronization as part of the rebuild. Action registry consumers still run after the registry, migrations, and action catalog update, and before reading settings shortcut definitions. Their contexts read the live registry. The action-shortcut presentation is constructed at the end of the update, after registration/conflict resolution, rather than both before and after registration. Standalone rebuilds and isolation-triggered shortcut synchronization still construct their own presentation.

The final presentation temporarily reuses that phase's shortcut definitions when an availability provider resolves a required shortcut. Bindings and conflicts are still resolved from current stores. A revision invalidates reuse on plugin state notification, reentrant rebuild, or isolation; nested projections restore the previous context without making an invalidated snapshot current. There is no persistent provider-definition or availability cache. Physical Clean Mode retains its valid-exit-shortcut check and execution-time safety validation.

New tests establish one availability projection per combined update, two definition reads across the existing settings and registration phases, live reads outside presentation, invalidation during a reentrant state change, and fresh registry/shortcut values after catalog-consumer callbacks. The initial host regression run passed 49 tests.

## Audio discovery

`AudioApplicationObservation` owns process subscriptions, event coalescing, fallback scheduling, and callback generations. `CoreAudioApplicationObservationWorker` supplies Core Audio queries/listeners and serial utility-queue scheduling. The main-actor monitor only filters unchanged or obsolete-session deliveries. Obsolete one-second scan-loop code is removed.

Process-list, process output-running, IO-running, output-scoped device-list, default-output-device, and service-restart listeners trigger reconciliation. A 50 ms fixed coalescing window avoids repeated scans during a burst without postponing work indefinitely. Successful subscriptions and reads use a ten-second fallback; failure uses one-second retry. Subscriptions precede activity reads. A failed process-list read preserves the last known state; a successful empty result removes applications. Service restart discards old listener tokens and establishes fresh subscriptions. Stopped sessions reject both worker events and already-queued main-actor deliveries.

Audio processing, helper ownership/grouping, persisted gains, permission handling, and routing remain active independently of panel visibility. No real-time audio callback or routing implementation changes. Apple documents listener block/queue lifetime in [AudioObjectAddPropertyListenerBlock](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)) and explicitly requires listener reestablishment after [audio-service restart](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyservicerestarted).

Deterministic tests cover idle cadence, playback bursts, process removal, output changes, subscription failure/retry, incomplete reads, service restart, explicit refresh, stop/restart, and stale callbacks. The first audio run passed 38 discovery, monitor, and plugin tests. Hardware-specific routing validation is separate from these fixtures.

### Real notification validation

The initial listener design watched only `kAudioProcessPropertyIsRunningOutput` per process. A temporary silent-audio helper demonstrated that registration success was insufficient: playback could change without a notification for that selector on this system. A diagnostic wildcard listener identified actual changes to `kAudioProcessPropertyIsRunning` at global scope and `kAudioProcessPropertyDevices` at output scope. The final implementation subscribes explicitly to those properties as well. Wildcard observation and extra logging exist only in the temporary probe, not production code.

The final probe compiles the actual discovery sources, creates the helper before playback, starts silent output after one second, stops it after two more seconds, and keeps the helper alive for another second. This separates process-list changes from playback-state transitions and finishes before the ten-second fallback. No permission request, gain change, device switch, or audio recording is performed. Initial failed probes are retained alongside the corrected probe results under `/private/tmp/mactools-stage2-audio-*`.

## Final validation and installed Dev observations

The 22 selected host, action, shortcut, window, safety, and audio test classes passed 297 tests. After correcting the observed Core Audio notification coverage, all 38 audio tests passed again. The final actual-source audio probe detected helper playback at 1.82 seconds and its stop at 4.01 seconds, while the helper was still alive and before fallback. These timestamps include helper startup, not isolated notification latency. The temporary helper emitted silence only.

`make script-tests` passed 270 tests, including changelog and generated-data validation. Its initial sandboxed attempt failed because Swift could not write its module cache and temporary-process checks lacked access; the normal-permission retry passed. `make generate`, the Debug build/install, and `git diff --check` passed. No commit was created.

The installed Dev process is PID 56897, with host debug binary timestamp 17:21:11. The standard development install synchronized 60 current plugin packages, retaining plugin preferences. Changes share the workspace with independent panel-presentation work; this fresh Dev installation includes those current sources as well. Whole-process measurements must not attribute all differences exclusively to this batch, and idle observations do not establish scrolling frame rate or total device power savings.

Artifacts: `/private/tmp/mactools-stage2-regression.xcresult`, `-audio-final.xcresult`, `-script-tests-retry.log`, `-install.log`, and `-audio-final-probe.json`.

### Process counters

Two independent 40-second windows ran without Time Profiler attached. Visibility probes found no Dev windows. One CPU core equals 100%.

| Metric | First window, before profiling | Second window, after profiling |
| --- | ---: | ---: |
| Mean CPU | 1.93% | 1.47% |
| Two-second CPU interval range | 0.04–5.89% | 0.11–3.91% |
| Interrupt wakeups/second | 17.64 | 10.95 |
| Physical footprint | 99.28–105.91 MiB | 161.70–161.86 MiB |
| Attributed CPU energy | 0.4394 J | 0.4041 J |
| Mean attributed CPU power | 10.96 mW | 10.08 mW |

Disk-read and disk-write counters did not advance in either window. CPU energy uses the same `RUSAGE_INFO_V6` accounting as the original audit; it excludes GPU/display/system-service energy and is not Activity Monitor's Energy Impact score. The earlier current-Dev audit observed 5.11% and 2.32% CPU in its two windows, but these are different workloads and process lifetimes, not a controlled savings experiment.

Memory grew between the two new windows, during an interval that included profiling and further runtime activity. Its cause is not established by these counters. The second window itself was nearly flat. Do not attribute the lower initial footprint to this patch, label the between-window increase a leak, or claim a memory reduction without allocation/retention evidence.

Artifacts: `/private/tmp/mactools-stage2-energy.ndjson`, `-energy-summary.json`, `-energy-repeat.ndjson`, `-energy-repeat-summary.json`, and the corresponding visibility JSON files.

### CPU stacks and remaining scope

The new 30.74-second Time Profiler recording at 17:24:16–17:24:46 contains 732 ms of Running sample weight, including 572 ms on the main thread. The earlier audit recording contained 583 ms total and 423 ms on the main thread. Thus this pair does **not** establish an overall main-thread or UI-latency improvement, even though the specifically targeted work decreased.

| Inclusive sampled work | Earlier current Dev audit | New Dev |
| --- | ---: | ---: |
| Application inventory reconciliation | 144 ms | 18 ms |
| `AnyHashable` equality within inventory reconciliation | 113 ms | 1 ms |
| Action-shortcut presentation under registry synchronization | 45 ms | 0 ms |
| Action-shortcut presentation under shortcut synchronization | 46 ms | 76 ms |
| Full resolver by plugin/shortcut ID | 18 ms | 0 ms sampled |
| Audio application snapshot query | 63 ms | 5 ms |

Inclusive rows overlap and must not be added. Zero sampled weight does not mean a function is never called. Tests establish the one-projection update boundary independently of statistical sampling.

The host group still accounts for 401 ms (54.78%) of the new trace, Window Switcher for 147 ms (20.08%), and App Volume for 8 ms (1.09%). Seven registry log events fall inside this recording, including two short bursts; each reports 52 providers, 290 catalog entries, and zero issues. The earlier audit reported 287 entries, so catalog contents also differ. The sampled stack does not identify the original dirty-plugin notifications.

The remaining host work includes fresh provider definitions, localization, permissions, settings projections, and live action availability. Before a further structural refactor, measure update causes and duration per dirty provider, then define invalidation for dynamic declarations and cross-provider dependencies. Do not increase coalescing latency, remove availability checks, or cache definitions indefinitely to hide this cost. Foreground settings scrolling and panel rendering still need a repeatable interaction trace; no frame-rate claim is made here.

Artifacts: `/private/tmp/mactools-stage2-after.trace`, `-after.xml`, `-after-summary.json`, `-target-stack-summary.json`, and `-trace-update-counts.json`. Raw Instruments recordings can include process environment metadata and should remain local; reports contain only the measurements needed for this analysis.
