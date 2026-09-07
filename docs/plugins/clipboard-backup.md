# Clipboard backup development and verification

Clipboard Backup belongs to the Clipboard History plugin's Local Data region. It is
independent of Preferences Backup and readable item Export. The format and
pre-implementation security review are recorded in the
[design](../superpowers/specs/2026-09-07-clipboard-backup-security.md).

Use temporary synthetic databases and fake Keychain stores for tests. Never seed,
replace, or clear the installed user's clipboard library for development checks.
The focused test command, after `make generate`, is:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test \
  -only-testing:MacToolsTests/ClipboardBackupServiceTests
```

The tests cover encrypted round trips, destination keys, selective membership,
merge conflicts, snippet keyword ownership, atomic replacement, SQLite-full
failure, authentication failures, malformed framing, cancellation, rollback,
missing file references, and a 128 MiB synthetic streaming memory regression.

The archive reader accepts at most 1,000,000 records and 100 GiB of archive data.
Individual payloads respect the configured capture limit, capped defensively at
64 MiB. Records are bounded before decode, with a 160 MiB absolute frame ceiling.
The encrypted manifest remains last so no second pass is needed to discover
backup counts. Counts and category membership are checked against every staged row.

Local rollback snapshots contain only the two persistent clipboard tables and
remain encrypted under the current Mac's key. They are intentionally not portable.
A successful replacement refreshes that snapshot in the same SQLite transaction as
the live data. Cancellation or storage failure preserves the previous recovery point.
Both databases use durable rollback journals for atomic commits across the files. Use Restore Local Rollback
Snapshot from Local Data to preview and confirm recovery. Plugin private-data
removal also removes these files. Temporary work directories use mode 0700 and
files use 0600; interrupted-process leftovers contain destination-encrypted data.

Ordinary clips with different IDs are retained even when digests match, preserving
meaningful provenance and titles. Snippets are never deduplicated by body. Conflict
and unresolved-file reports are encrypted on disk and paged in the sheet.

For manual acceptance with an isolated Debug identity, verify save/open panels,
password confirmation, keyboard navigation, progress cancellation, precise partial
replacement labels, destructive confirmation, report paging, and recovery after
reopening Local Data. Do not install or sync this branch over a shared Debug app.

Backup copy is included for every locale declared by the plugin manifest.
