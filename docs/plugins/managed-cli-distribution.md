# Managed CLI installation

MacTools can install and maintain a separate Apple silicon CLI using metadata sealed inside the signed app. Nightly publishes this metadata. Stable support exists in source, but normal stable publication remains disabled; see [CLI release gates](cli-release.md). Intel, development, unsigned, and manifest-less builds cannot complete managed installation.

For installation steps, use the [Nightly guide](../testing/cli-nightly-distribution.md#install-from-settings). For commands and JSON responses, see [CLI agent usage](../cli/agent-usage.md).

## Channels and ownership

| Channel | Public command | Private store |
| --- | --- | --- |
| Stable candidate | `~/.local/bin/mactools` | `~/Library/Application Support/MacTools/CLI/<owner>/` |
| Nightly | `~/.local/bin/mactools-nightly` | `~/Library/Application Support/MacTools Nightly/CLI/<owner>/` |

The owner hash binds the signing identity, Team ID, and publisher release URL prefix. Different publishers cannot adopt each other's installations. A public-command collision is reported rather than overwritten. Stable and Nightly keep separate commands, stores, and broker identities.

Each version directory contains `mactools`, `LICENSE`, and an ownership receipt with the manifest, executable hash, managed path, and public link path. The public command points to `<root>/current/mactools`; updates change only the private relative `current` symlink. Initial public-link creation is exclusive, and later updates preserve its inode.

## Packaging and trust

`scripts/cli-install-manifest.py` creates schema-1 `cli-install.json` beside the CLI ZIP and inside `Contents/Resources/` of the app. It records versions/builds, channel, architecture, source commit, immutable release and asset URLs, archive digest/size, signing identity, and protocol range.

The packaging order is:

1. Sign the CLI and package exactly `mactools` and `LICENSE`.
2. Generate and embed the installation manifest from those exact archive bytes.
3. Sign the outer app, then complete app and CLI notarization and verification.
4. Publish the verified artifacts without repackaging the CLI or changing the sealed manifest.

Only the manifest inside the locally verified Developer ID app signature is authoritative. The public JSON is informational. The CLI must match the developer identity and its separate `.cli` signing identifier, pass notarization checks, and support a compatible protocol. Downloaded and extracted files retain quarantine; verification failures are not repaired by re-signing or removing quarantine.

GitHub release URLs are immutable `/releases/download/nightly-<run>-<attempt>` or `/releases/download/v<version>` directories. Personal publishers may use immutable HTTPS `/releases/<build>` directories.

## Download and archive limits

| Boundary | Validation |
| --- | --- |
| Network | HTTPS redirects without credentials; ephemeral session without persistent cookies, credentials, or URL cache |
| Deadline | 30-second request timeout and 120-second resource deadline |
| Download size | Manifest byte count, capped at 64 MiB |
| Archive entries | Exactly two regular entries: `mactools` (0755) and `LICENSE` (0644) |
| Archive structure | Checked local/central records; no traversal, symlinks, encryption, extra records, unsupported ZIP forms, or oversized content |
| Verification subprocesses | Bounded output and deadlines |

Requests contain no app/plugin data, action history, or repository credentials. Managed filesystem operations reject redirected parents, unrecognized children, hard-linked or changed executables, and receipts belonging to other owners.

## Updates, rollback, and removal

The first installation requires confirmation and includes automatic updates with MacTools. App launch reconciles an active owned installation with the app build; it never installs for users without an active receipt, including after removal. Legacy installations with automatic updates disabled also reconcile under this policy.

| Operation or failure | Result |
| --- | --- |
| Activation | A durable journal records the candidate, previous version, rollback hold, and pending validation before changing `current` |
| Validation | `version --json` must pass; `doctor --json` must also pass when the broker is enabled. No action is executed or replayed |
| Failed or interrupted activation | Restore the previous pointer; retain the journal and report an ownership/filesystem problem if external changes prevent recovery |
| Explicit rollback | Keep the retained version for the current app release; an explicit Update or the next app release resumes matching updates |
| Downgrade | Reuse a matching retained build when available |
| Cleanup | Validate ownership before retiring unused versions; preserve the active, rollback, and matching retained candidate versions |

A private file lock serializes managed operations across processes. At most three versions remain after an update. Retention failure leaves the active CLI unchanged.

Cleanup first moves validated unused versions into `.delete-<version>` directories. Recovery accepts partial contents only there, revalidates remaining payloads, and removes the receipt last after durable payload deletion. Interrupted cleanup resumes on launch or the next operation. The app never recursively deletes arbitrary directories, foreign entries, or protected active/rollback versions.

Protocol negotiation remains authoritative after installation: incompatible app/CLI pairs cannot execute actions, while local commands remain available.

## Personal publishers

Generate the manifest in the candidate release directory after `prepare_cli` and before app signing. Pass the source commit, publisher team, exact archive, and immutable release URL to `scripts/cli-install-manifest.py`. Include the resulting JSON in the release checksum manifest; schema-2 manual releases may optionally declare it as `cli.install_manifest`.

Verify version/build, source, architecture, hash, and size before promotion. Never append metadata to an existing published release or re-sign an already notarized app. Legacy builds without sealed metadata retain manual installation only.

## Verification

Use the affected cases in `CLIManagedInstallationTests`, `CLIArchiveTests`, and `CLIInstallerTests` for ownership, activation, rollback, and malformed archives. They use temporary stores and injected failures. Follow the shared [validation policy](../../CONTRIBUTING.md#validation) for script or cross-module changes.

Before publishing installer changes, complete the relevant signed installation, background-item approval, update, rollback, and channel-coexistence checks in the [distribution guide](../testing/cli-nightly-distribution.md). Unit tests and unsigned Debug builds do not establish notarization or the installed app-to-CLI broker path.
