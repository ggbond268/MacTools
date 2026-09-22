# Encrypted clipboard backup

Create and restore clipboard archives from **Clipboard History → Local Data**. Clipboard Backup is separate from Preferences Backup and readable item Export.

## Create and restore

1. Choose a destination for a new backup, or a file to restore.
2. Enter the backup password. New passwords require at least 12 user-perceived characters and at most 1,024 UTF-8 bytes.
3. Choose **Create Backup** to write an archive, or validate a restore to preview its contents.
4. Review the scope and conflicts, then merge or explicitly confirm replacement.

Choosing a save location does not write a backup. Restore validation only stages a preview; cancelling replacement confirmation leaves the preview and local data unchanged. Completion offers **Done**, with conflict and missing-file reports still accessible.

Restore accepts older passwords without the new character minimum, subject to the existing byte limit. Password encoding remains UTF-8.

## Merge behavior

| Case | Result |
| --- | --- |
| Ordinary clips with different IDs | Retained even when digests match, preserving provenance and titles |
| Snippets with matching bodies | Not deduplicated by body |
| Matching-ID import without optional Universal Clipboard metadata | Existing known provenance is retained |
| Remote-source item | Cannot retain an unrelated local-app field |
| Missing file reference | Reported for review |
| Snippet keyword capacity exceeded | Preview identifies affected bindings; explicit **Continue Merge** confirmation is required |

Keyword capacity is checked against the final staged library after removals and metadata merges. Existing local bindings take priority, then imported bindings in archive order. A binding that does not fit is disabled; later smaller bindings may still fit. Snippet bodies remain intact, and cancellation preserves the preview and local data.

Conflict and missing-file reports are encrypted on disk and paged in the sheet. Metadata-only planning, disk-backed ordering, and transactional report writes bound memory and avoid a disk synchronization for each disabled keyword.

## Local rollback

**Restore Local Rollback Snapshot** previews recovery from the last local replacement point. These snapshots contain only the two persistent clipboard tables and remain encrypted under the current Mac's key; they are not portable backups.

A successful replacement refreshes the snapshot in the same SQLite transaction as live data. Cancellation or storage failure preserves the previous recovery point. Both databases use durable rollback journals for atomic commits across files. Plugin private-data removal also removes these snapshots.

## Format and resource limits

The archive reader enforces limits before decoding:

| Resource | Limit |
| --- | --- |
| Records | 1,000,000 |
| Archive size | 100 GiB |
| Item payload | Configured capture limit, capped at 64 MiB |
| Encoded frame | Absolute ceiling of 160 MiB |
| Password derivation input | 1,024 UTF-8 bytes |

The encrypted manifest is last, allowing counts to be discovered without a second pass. Counts and category membership are checked against staged rows. Temporary directories use mode 0700 and files use 0600; interrupted-process leftovers contain destination-encrypted data. See the [format and security design](../superpowers/specs/2026-09-07-clipboard-backup-security.md) for the rationale.

## Verification

Use temporary synthetic databases and fake Keychain stores. Never seed, replace, or clear a user's installed clipboard library for development checks.

After `make generate`, run the affected cases or the focused service suite:

```bash
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/ClipboardBackupServiceTests
```

Existing coverage includes encrypted round trips, scope and merge rules, provenance, keyword-capacity confirmation, authentication/framing failures, atomic replacement, cancellation, rollback, and a synthetic streaming-memory regression. Reuse it; add tests only for a missing core outcome or regression.

For UI changes, check the affected save/open, password, preview, confirmation, progress/cancellation, or report flow with an isolated Debug identity. Use screenshots and manual interaction for layout/copy changes. The existing view checks cover all 11 locales, including Arabic right-to-left layout; new tests need not repeat that matrix for every edit. Counts and file sizes follow the runtime locale.
