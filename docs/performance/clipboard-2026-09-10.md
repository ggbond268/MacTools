# Clipboard opening latency

Measured with synthetic in-memory records, Debug plugin products, and a native AppKit
window on arm64 macOS. No user clipboard, database, or preferences were accessed.

## Findings and changes

- Initial presentation counted filter metadata twice and sorted dictionary keys separately
  for each scope. It now counts once, preserves sorted input, and sorts mixed input once.
- The detached preparation worker used to start only after a main-actor task could run.
  It now starts before native window construction. Plugin activation also prepares the
  first page after both stores load, without creating a window or loading preview payloads.
- Opening during that background preparation reuses the pending scan. Revision checks
  and cancellation still reject snapshots invalidated by copies, edits, or deletion.
- The history panel opens without the utility-window transition and skips unchanged frame updates.
- The latest bounded rich-text preview survives an ordinary close, including prepared
  light/dark colors. Failed reads are retried; deletion, explicit discard, deactivation,
  and memory pressure invalidate the cache. Source payloads are still released.
- Selection availability and snippet reconciliation reuse maintained identifier sets.

## Native window measurements

`ready` measures `show()` through completed first-page preparation and an explicit
AppKit layout/display flush. It excludes application launch, global shortcut dispatch,
physical display presentation, and asynchronous preview completion. A standalone probe
also pays SwiftUI's first-use cost that an already-running host may have paid earlier.

| Records | Original first open | Updated first open after preparation | Updated reopens |
| --- | ---: | ---: | ---: |
| 1,000 | 347 ms | 221 ms | 22 ms |
| 10,000 | 600 ms | 227 ms | 21 ms |

Original values are single exploratory baseline runs recorded before editing. Updated
first-open values are medians of three separate processes; reopen values are medians
of their fifteen reopens. These are indicative comparisons, not controlled release benchmarks.
At 10,000 records, opening without advance preparation took a median 270 ms across
three processes. Advance metadata preparation itself took approximately 68 ms in the
first measured run. The supported history limit is 10,000 records.

Reproduce with:

```sh
bash scripts/benchmarks/clipboard.sh Debug window 1000
bash scripts/benchmarks/clipboard.sh Debug window 10000
bash scripts/benchmarks/clipboard.sh Debug window 10000 --cold
```

## Verification and remaining limits

Targeted XCTest coverage checks index ordering/counts, large cold and warm presentations,
copy/delete/snippet mutations, revision invalidation, joining an in-progress preparation,
rich-preview reuse, retries, and cancelled or discarded imports. A native activation
probe also confirmed that activation and reactivation prepare 50 rows without creating
a panel or activating previews.

Existing pagination, targeted metadata updates, bounded image/PDF caching, asynchronous
payload persistence, and serial background OCR remain in place. No OCR work is triggered
by opening the panel. First-ever native view construction and importing a previously
unseen rich document still have costs; the measurements above do not cover those preview
imports or the full shortcut-to-visible-frame path in the installed app.
