# Storage Explorer

Storage Explorer is a metadata-only, user-initiated disk usage browser. It does not open file contents during scanning. Selecting a local regular file in the inspector can request a Quick Look preview.

## Scanning and shared metadata

`MacToolsFileSystem` is a static module shared with Disk Clean. Its bulk parser preserves the existing Disk Clean attribute contract; Storage Explorer requests additional allocation, modification date, and file flag attributes. Unsupported bulk reads fall back to descriptor-relative enumeration. Directory opens reject symbolic-link path components. Unreadable directories, cloud-only directories, mount boundaries, invalid filename encodings, and missing metadata make results incomplete instead of appearing empty and complete.

The scanner defaults to two workers, capped at four. Blocking calls stay outside Swift's cooperative executor. Progress is time-throttled to 150 ms with initial and final updates. Cancellation is checked between batches and jobs; a blocking filesystem syscall cannot be forcibly interrupted. Packages remain atomic in the results, with nested payload included. Hard links are deduplicated across all workers and package boundaries; the first encountered link receives the counted bytes.

The UI uses a flat path index and background result projections. The treemap draws at most 160 items plus an Other group. The native table displays up to 5,000 matching rows and searches the complete selected scope. File-type totals and largest-file results span the scan root; folder mode shows immediate children. Logical and allocated sizes are separate, and neither is a promise of recoverable disk space.

## Refresh and retention

Scan snapshots remain in memory. Directory metadata is cached for at most 30 seconds and 100,000 entries. FSEvents invalidates affected ancestors/subtrees, and dropped or root-change events clear the cache. Refresh drains pending file events before cache reuse, re-enumerates invalidated directories and recomputes hard-link accounting. The Refresh context menu also offers a full rescan. If an event arrives during a scan, results remain marked stale until refreshed. No scan paths or results are persisted or sent over the network.

Trash review is unavailable during scanning, for incomplete/stale results, and for protected paths. The review basket spans folders, normalizes ancestor/descendant overlap, and freezes its item list for confirmation. Trash operations revalidate paths through the existing safety policy. Successful removal starts a fresh scan instead of subtracting an assumed freed-byte count.

## Validation

Run the StorageExplorer scanner, progress, controller, presentation, and safety-policy XCTest classes, plus DiskClean bulk-parser and walker tests. Run `make script-tests` after changing module/project integration. Benchmark optimized builds on synthetic many-small-file trees, deep trees, packages, and sparse files; compare full duration, first useful update, callbacks, and memory separately. Local synthetic benchmarks do not establish external-drive, cloud-provider, or network-filesystem performance.

The standalone benchmark creates and deletes only its own temporary fixture:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer python3 scripts/benchmark-storage-explorer.py --files 20000 --baseline-ref f98fe198
```

On a local 20,000-file fixture, the baseline took 1.09–1.16 seconds and the default two-worker scanner took about 0.116 seconds with an empty scanner cache. This is a warm-filesystem synthetic comparison, not a cold-disk or external-drive guarantee. The benchmark also reports callback counts, first useful update, cached directory count, and process peak resident memory.
