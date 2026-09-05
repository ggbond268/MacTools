# Clipboard responsiveness comparison — August 28, 2026

## Scope and provenance

This pass improves model updates and unchanged reopening, makes hidden export menus
lazy, isolates asynchronous image/PDF preview state from the panel root, and adds a
bounded window-scoped thumbnail cache. Normal selection reveals an offscreen row
without unnecessarily centering an already-visible row. Selection order, filtered
membership, action-target validation, encryption, and paste pacing are preserved.

The baseline is the working tree immediately before this performance pass, including
the preceding uncommitted mutation architecture changes, on committed HEAD
`dc9346e838e3b6113bde25c5bd8e9cd1ab8ae96c`. It is **not** the older installed app.
No installation, relaunch, database change, commit, or push was performed in this pass.

Model probes were compiled separately for Debug (`-Onone`) and Release (`-O`) with
Apple Swift 6.4 / Xcode beta on arm64 macOS 27. The original plugin core was frozen
inside static-linked probe binaries before source edits. PluginKit was not changed
by this performance pass. Original binary SHA-256 values:

- Debug: `1d94ca94c3192a19560fa619899d1f71a37996506bca993c390e0d5586e7fa4c`
- Release: `9b26e0d171c488f3d70f5005c61f2e78fe5c724b2435beda96a6636a502d5b00`

After final builds/tests stopped, each original/updated pair ran sequentially three
times per configuration. Tables report the median, in milliseconds. The fixtures
are generated short text clips; construction is outside the timer. Fifty thousand
items is a stress case, 100 times the default 500-item history limit.

These numbers exclude SwiftUI frame rendering, real database/keychain reads, disk
payload loads, and unrelated host/plugin work. They demonstrate reduced work, not
proof that every perceived UI delay is fixed. The SwiftUI performance/refactor audit
guided preview-local state and deferred hidden-menu construction; those rendering
changes still need visual and frame-profile validation in the installed app.

## Comparable model operations

The metadata test changes one item's last-used timestamp and calls the same
full-snapshot `updateItems` entry point before and after. Completion includes any
result search it schedules. This is deliberately more conservative than timing only
the new controller-to-panel known-ID fast path.

| Build | Items | Unchanged reopen: before → after | Metadata completion: before → after |
|---|---:|---:|---:|
| Release | 500 | 0.508 → 0.014 | 0.556 → 0.159 |
| Release | 5,000 | 4.849 → 0.012 | 5.145 → 0.993 |
| Release | 50,000 | 57.230 → 0.015 | 86.017 → 10.818 |
| Debug | 500 | 2.334 → 0.016 | 1.603 → 0.580 |
| Debug | 5,000 | 23.416 → 0.018 | 15.265 → 4.936 |
| Debug | 50,000 | 239.150 → 0.024 | 193.788 → 50.091 |

For every fixture size, the metadata update now produces **one model notification
instead of eight**, with no new search when membership is unchanged. Notifications
are not rendered frames; SwiftUI may coalesce them.

A separate diagnostic run of the actual known-ID path, with an active `88` query,
measured 0.056 / 0.164 / 1.683 ms in Release at 500 / 5,000 / 50,000 items, and
0.095 / 0.235 / 1.727 ms in Debug. Each produced one notification and no search.
These are single-run diagnostics, not the three-run comparison above. Array lifetime
and copy-on-write costs can still scale with collection size even without rebuilding
all lookup tables.

Warm reopening means the source collection and saved library are unchanged. A real
mutation invalidates the prepared page; it never reuses stale results or hidden
filter availability merely to improve a benchmark.

## Image-preview reuse

Three separate Release runs used a generated 2,400 × 1,800 PNG and the same current
decoder with and without caching. Median results:

| Operation | Time | Decodes |
|---|---:|---:|
| Ten uncached preview visits | 132.975 ms | 10 |
| Ten cached visits, including first decode | 13.015 ms | 1 |
| Ten already-warm cache visits | 0.0025 ms | 0 |

This is a within-build caching comparison, not image timing against the frozen old
binary. The real-image benchmark caught Retina-scaled `NSCGImageSnapshotRep` size
reporting that made a thumbnail appear four times larger for cache budgeting. The
decoder now keeps an explicit bitmap representation; a real-PNG test verifies its
1,600 × 1,200 pixel bound and reuse.

The cache allows at most eight thumbnails and 32 MiB of budgeted pixel storage,
counting eight bytes per pixel conservatively. This fixture costs 15,360,000 bytes.
LRU eviction, deletion/payload-digest invalidation, coalescing, and cancellation are
tested. It is cleared when the panel closes and retains no source clipboard payloads.
The byte budget is not a claim about total process RSS or all AppKit allocations.

## Controls and remaining work

This pass does not claim a general cold-open or search optimization. The following
50,000-item controls are included to avoid reporting only the improved paths:

| Operation | Release: before → after | Debug: before → after |
|---|---:|---:|
| Cold synchronous preparation | 61.801 → 53.901 | 226.555 → 242.966 |
| Cold preparation plus first page | 70.329 → 61.018 | 269.261 → 290.101 |
| Search `88`, including 120 ms debounce | 142.352 → 142.570 | 176.412 → 179.640 |
| Retention evaluation | 37.708 → 44.714 | 131.153 → 128.565 |

The controls vary, including slower Debug cold preparation and Release retention in
this sample. Retention/search algorithms were not changed by this pass; timings in a
resident model are also affected by memory state and normal machine variability.
Do not label these paths improved or infer that they are regression-free from this
small sample. Checkbox bookkeeping remains around 0.002–0.003 ms per toggle; it was
not the demonstrated bottleneck.

Next priorities are cold snapshot/filter preparation off the main actor, event-driven
retention rather than repeated collection-wide work, adversarial fragment-search
benchmarks, and profiling host notification fan-out during actual interactions.
Rich-text imports and queue-HUD previews do not yet share this panel thumbnail cache.
Further optimization must retain complete matching, deletion/action safety, and
ordered paste behavior instead of shortening necessary safeguards.

## Regression verification

- 250 affected controller, panel keyboard, plugin, mutation, and cache tests passed.
- After the real-image sizing fix, 18 focused preview/cache/metadata tests passed
  (including overlapping cache tests and the new actual PNG case).
- Debug test builds and the final Release plugin build succeeded.
- Changelog validation, benchmark shell syntax, and `git diff --check` passed.
- Subsequent pre-push `make ci` passed all 3,617 XCTest cases, 187 repository script
  tests, changelog validation, and the PluginKit v5 binary-compatibility client.
- No claim is made here about GitHub CI or fresh visual snapshots.

Coverage includes unsaving from Saved scope and refilling the page, entering/leaving
an active query through metadata, stale in-flight search results, stable ordered
selection, reordered snapshots, controller publication integration, invalidated warm
pages, cache cancellation/eviction, and a conservative 150 ms model budget for warm
reopen and known-ID updates with 50,000 clips.

Reproduction commands and measurement boundaries are in
[the benchmark README](../../scripts/benchmarks/README.md).
