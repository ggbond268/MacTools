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

## Nightly and local stable validation

Use signed Nightly builds to validate shared installer behavior. Existing results apply to their recorded source and artifacts; changed behavior requires fresh checks. Then validate a locally built, signed and notarized stable candidate for stable signing/broker identities, metadata, command/store paths, and coexistence with Nightly. Complete the advertised OS matrix, including macOS 14, before enabling stable publication.

Build local candidates from a recorded source commit, using the intended stable identity and version/build. A release tag is not required for local validation. After release-operator authorization, use the same packaging order as production:

1. Build the Release app and separate CLI. Preserve the app's supported architectures and thin only the CLI to arm64.
2. Sign the CLI with Developer ID and package exactly `mactools` and the GPL license using `scripts/nightly-release.py package-cli`.
3. Generate channel-bound metadata with `scripts/cli-install-manifest.py`, using an authorized immutable HTTPS test-distribution URL, and embed it before signing the outer app. The distribution must serve the exact archive bytes named in that manifest for in-app download testing.
4. Sign the app and DMG, submit the DMG and CLI ZIP separately for notarization, and verify their results. Use `verify-cli-archive --channel stable --skip-execution` for static CLI checks.
5. Transfer the verified artifacts to the test environment without signing or publication credentials. Verify the archive again, execute `version --json`, and exercise real in-app installation, permissions, updates, rollback, removal, and stable/Nightly coexistence. Keep normal quarantine behavior and record hashes and outcomes.

The shared packaging and verification subcommands in `scripts/nightly-release.py` support both channels. `scripts/release-local.sh` continues producing app-only releases; it does not automatically package a managed stable CLI. Candidate preparation must explicitly follow the CLI packaging and metadata-sealing steps above.

Never change metadata after signing, replace published assets at an existing tag, re-sign downloaded product binaries to bypass verification, or remove quarantine. Do not enable the publication gate merely to make test downloads available. No stable candidate was signed or published as part of implementing this support.

The **Release** workflow retains normal tag-based checkout and publication semantics, including when started manually. It has no candidate-only mode and must not be dispatched as a dry run. Local validation avoids creating a release tag that would trigger normal publication.

## Stable publication

`.github/workflows/release.yml` commits `STABLE_CLI_ENABLED: "false"`. Ordinary stable builds therefore do not include installation metadata or publish CLI assets. A separate reviewed change can enable it only after the [acceptance report's remaining checks](../cli/validation/2026-09-10-nightly-signed-acceptance.md) and stable-specific signed tests pass, including macOS 14 and simultaneous stable/Nightly installations.

When enabled, the release workflow signs and notarizes the separate CLI, seals its metadata before app signing, and statically verifies it. Publication depends on the signing job and the credential-isolated CLI verification job, which verifies and executes the archive on a separate runner. The publisher downloads the same artifact ID, includes the separately verified ZIP/checksum and informational manifest, and refuses to overwrite an existing stable CLI release tag. The app's embedded metadata is authoritative. No CLI executable is embedded in the app, no shell files are changed, and users who have not installed the CLI receive no automatic CLI installation.

Code/unit tests, candidate archive smoke tests, signed native installation/permission checks, full Sparkle updates, and release approval are separate evidence. Track the remaining Nightly matrix in #403 and stable rollout in #417; this implementation alone closes neither issue.
