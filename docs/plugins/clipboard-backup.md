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
merge conflicts, snippet keyword ownership and capacity confirmation, atomic replacement, SQLite-full
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

Backup copy is included for every locale declared by the plugin manifest. The
view test resolves compiled backup strings and renders creation, restore entry,
password entry, and completion in all 11 locales, including Arabic right-to-left
layout. Counts and file sizes follow the runtime locale.

The sheet selects the file or destination before requesting a password. Choosing a
save location does not write an archive: Create Backup starts that operation.
Restore validation only stages a preview; the merge action or destructive
replacement confirmation commits it. Cancelling replacement confirmation keeps
the preview available without changing local data. Completed operations offer
Done only, with conflict and missing-file reports still accessible. The scrolling
content keeps the footer visible when reports expand.

New backup passwords require at least 12 user-perceived characters (Swift
`String.count`). Key derivation retains the 1,024-byte resource limit and the
original UTF-8 encoding. Restore does not apply the new character minimum, so
existing archives with shorter multibyte passwords remain readable.

Keyword capacity is checked against the final staged library after scoped removals
and metadata merges. Existing local bindings have priority, followed by imported
bindings in backup order; a candidate that does not fit loses only its keyword
binding, and later smaller candidates can still fit. All snippet bodies remain
intact. The preview reports the affected count and names before an explicit
Continue Merge confirmation. Cancelling keeps the preview and local data intact.
The commit API also requires explicit capacity-loss acceptance. Metadata-only
planning, disk-backed ordering, and transactional report writes bound memory and
avoid one disk synchronization per disabled keyword. The wire format is unchanged.
