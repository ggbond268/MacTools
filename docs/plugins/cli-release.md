# CLI candidate packaging and release gates

Stable CLI direction and initial platforms are approved in [#417](https://github.com/ggbond268/MacTools/issues/417): a separate optional Apple-silicon download, General-settings installation, and the app's minimum macOS version (currently 14). Publication is still gated on signed validation. This does not change plugin package publication or CLI action eligibility.

## Channels and trust

| Property | Stable | Nightly |
| --- | --- | --- |
| Command | `~/.local/bin/mactools` | `~/.local/bin/mactools-nightly` |
| Managed store | `Library/Application Support/MacTools/CLI/<owner>` | `Library/Application Support/MacTools Nightly/CLI/<owner>` |
| Host signing suffix | `.mactools` | `.mactools.nightly` |
| CLI signing suffix | `.mactools.cli` | `.mactools.nightly.cli` |
| GitHub release directory | `/releases/download/v<version>` | `/releases/download/nightly-<build-with-dashes>` |

Each owner derives from the signing identity, team, and distribution location. Existing Nightly owner hashes and paths remain unchanged. Both channels also support immutable HTTPS `/releases/<build>` distribution directories. Stable and Nightly receipts, commands, broker identities, and state must remain isolated. Unmanaged files, directories, dangling links, Homebrew links, and other publishers' commands are rejected rather than replaced.

The app trusts only `Contents/Resources/cli-install.json` sealed by its Developer ID signature. The channel must match the app's `MTReleaseChannel` and signing identity. Architecture, app/CLI versions and builds, protocol range, archive shape, digest, identity, and notarization remain validated before activation. A metadata resource only makes the stable installer visible; it does not bypass authentication. Development and Intel builds do not expose managed installation.

## Candidate-only validation

After explicit release-operator authorization, dispatch the **Release** workflow with a matching version tag and `cli_candidate: true`. This builds and notarizes a candidate and uploads its artifacts, but the publication job is excluded. It does not create a GitHub release, advance the appcast, or update app-release metadata on main. No workflow was dispatched as part of implementing this support.

The candidate workflow:

1. Builds the Release app and separate CLI, preserving the app's supported architectures and thinning only the CLI to arm64.
2. Signs the CLI with Developer ID and packages exactly `mactools` and the GPL license.
3. Generates channel-bound metadata with `scripts/cli-install-manifest.py` and embeds it before signing the outer app.
4. Signs the app and DMG, submits the DMG and CLI ZIP separately for notarization, and statically verifies the CLI without executing it in the signing job.
5. Uploads one immutable candidate artifact containing the DMG/checksum, CLI ZIP/checksum, installation manifest, and generated release metadata.
6. Downloads that exact artifact ID on a separate runner, verifies the stable CLI's architecture, macOS deployment target, embedded identity/version, Developer ID signature, dependencies, and checksum, then executes `version --json`. That runner has no signing or publication credentials and checkout does not persist Git credentials.

Candidate metadata references the intended immutable release URL. Since candidate-only runs do not publish that URL, signed in-app download validation needs an explicitly authorized test distribution with matching metadata generated before app signing. Never change metadata after signing, replace assets at an existing tag, re-sign downloaded product binaries to bypass verification, or remove quarantine. The publication gate must not be enabled merely to make candidate downloads available.

Local packaging can use the same `package-cli` and `verify-cli-archive --channel stable` subcommands in `scripts/nightly-release.py`; their shared archive/signature checks are reused for both channels. `scripts/release-local.sh` continues producing app-only releases and does not enable managed stable CLI installation automatically.

## Stable publication

`.github/workflows/release.yml` commits `STABLE_CLI_ENABLED: "false"`. Ordinary stable builds therefore do not include installation metadata or publish CLI assets. A separate reviewed change can enable it only after the [acceptance report's remaining checks](../cli/validation/2026-09-10-nightly-signed-acceptance.md) and stable-specific signed tests pass, including macOS 14 and simultaneous stable/Nightly installations.

When enabled, publication depends on the signing job and the credential-isolated CLI verification job. The publisher downloads the same artifact ID, includes the separately verified ZIP/checksum and informational manifest, and refuses to overwrite an existing stable CLI release tag. The app's embedded metadata is authoritative. No CLI executable is embedded in the app, no shell files are changed, and users who have not installed the CLI receive no automatic CLI installation.

Code/unit tests, candidate archive smoke tests, signed native installation/permission checks, full Sparkle updates, and release approval are separate evidence. Track the remaining Nightly matrix in #403 and stable rollout in #417; this implementation alone closes neither issue.
