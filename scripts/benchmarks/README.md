# Clipboard performance probes

These probes use generated text and image data. They never open the user's database,
read the system clipboard, install the app, or change settings. Timings cover model
work and decoding, **not rendered frames or end-to-end app responsiveness**.

Build the plugin in each configuration you want to measure:

```sh
make generate
xcodebuild -project MacTools.xcodeproj -scheme ClipboardHistoryPlugin \
  -configuration Release -derivedDataPath build/DerivedData ENABLE_TESTABILITY=YES build -quiet
bash scripts/benchmarks/clipboard.sh Release panel
bash scripts/benchmarks/clipboard.sh Release panel --targeted
bash scripts/benchmarks/clipboard.sh Release previews
```

Use the same commands with `Debug` to measure development builds. Set `DEVELOPER_DIR`
when the intended Xcode is not the system default. The preview probe needs macOS
LaunchServices image-type lookup; a restricted shell can deny that lookup even when
ImageIO itself can decode the generated PNG.

The panel probe covers 500, 5,000, and 50,000 short text clips. Fixture construction
is outside the timers. It records cold preparation, completed first-page search,
unchanged reopening, a metadata update, model publication count, selection bookkeeping,
substring search including its intentional 120 ms debounce, and retention evaluation.
`metadataFull` includes any result-search completion. `--targeted` additionally measures
the controller's new known-ID update path while a query is active; the default probe
uses full-snapshot reconciliation so before/after measurements exercise the same API.

The preview probe creates a 2,400 × 1,800 PNG and compares ten uncached loads with
ten cache visits, including the first decode. It also reports ten already-warm visits,
decode count, and budgeted thumbnail bytes. This comparison isolates caching within
one build; it is not a frozen-old-binary image benchmark.

For comparisons, build and preserve the original probe binaries **before** changing
the source. The plugin core is linked statically, but PluginKit remains dynamic, so
keep its matching framework as well if PluginKit changes. Run original and updated
binaries sequentially, alternate them, and repeat at least three times with other
builds/tests stopped. Report medians and the dataset/configuration, not one best run.
Do not interpret microsecond cache lookups as microsecond window rendering.

See [the August 28 comparison](../../docs/performance/clipboard-2026-08-28.md) for
measured results, remaining bottlenecks, and regression coverage.
