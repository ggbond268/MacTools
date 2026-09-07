# Test the downloadable Nightly CLI

MacTools Nightly publishes the experimental `mactools` CLI as a separate optional download. The CLI is not embedded in `MacTools Nightly.app` and does not increase the app download size. Use the app and CLI from the same [`nightly-*` prerelease](https://github.com/ggbond268/MacTools/releases) for this test.

The Nightly archive is a notarized ZIP named `mactools-cli-<version>-<build>-macos-universal.zip`. It contains one signed executable for Apple silicon and Intel Macs. Nightly CLI and stable CLI identities are intentionally separate; this prototype connects only to the Nightly app's broker.

## Download and verify

Download these four assets from one Nightly release:

- `MacTools-Nightly.dmg`
- `MacTools-Nightly.sha256`
- `mactools-cli-<version>-<build>-macos-universal.zip`
- the matching `.zip.sha256`

From the download directory, replace the example archive name with the exact release asset name:

```bash
shasum -a 256 -c MacTools-Nightly.sha256
shasum -a 256 -c mactools-cli-1.2.1-123.1-macos-universal.zip.sha256
ditto -x -k mactools-cli-1.2.1-123.1-macos-universal.zip mactools-cli
codesign --verify --strict --verbose=2 mactools-cli/mactools
codesign --display --verbose=4 mactools-cli/mactools 2>&1 \
  | grep -E '^(Identifier|Authority|TeamIdentifier)='
lipo -archs mactools-cli/mactools
spctl --assess --type execute --verbose=2 mactools-cli/mactools
```

The architecture output must contain exactly `arm64 x86_64`. The signing identifier must end in `.mactools.nightly.cli`, the authority must be the MacTools Developer ID Application certificate, and the Team ID must match the Nightly app.

Do not remove quarantine attributes or re-sign the executable if validation fails. Confirm that all files came from the same GitHub release, verify their checksums again, and report the release tag and validation output.

## Try the CLI without installing it

Install `MacTools Nightly.app` from the DMG and launch it once. In **Settings > General > Command Line**, enable Command-Line Integration. Allow the MacTools Nightly background item in **System Settings > General > Login Items** if macOS requests approval.

Use the extracted executable by absolute path first:

```bash
"$PWD/mactools-cli/mactools" version --json
"$PWD/mactools-cli/mactools" doctor --json
"$PWD/mactools-cli/mactools" actions list --json
```

Copy complete action IDs from `actions list`; do not shorten or reconstruct them. To exercise and restore the harmless Night Shift toggle, record its current state and run:

```bash
"$PWD/mactools-cli/mactools" actions describe night-shift/toggle --json
"$PWD/mactools-cli/mactools" actions availability night-shift/toggle --json
"$PWD/mactools-cli/mactools" actions run night-shift/toggle --timeout 15 --json
"$PWD/mactools-cli/mactools" actions run night-shift/toggle --timeout 15 --json
```

Both runs should exit 0 and restore the recorded state. If either run fails, restore Night Shift manually in System Settings.

## Install on `PATH`

After the absolute-path checks pass, install the signed executable for the current user:

```bash
mkdir -p "$HOME/.local/bin"
/usr/bin/install -m 0755 "$PWD/mactools-cli/mactools" "$HOME/.local/bin/mactools"
codesign --verify --strict --verbose=2 "$HOME/.local/bin/mactools"
"$HOME/.local/bin/mactools" doctor --json
```

Add `$HOME/.local/bin` to `PATH` if needed. Remove this installation with:

```bash
rm "$HOME/.local/bin/mactools"
```

Disable Command-Line Integration before removing MacTools Nightly. The CLI and app may be upgraded independently when their negotiated protocol ranges overlap, but testing the same Nightly release removes avoidable compatibility uncertainty.

## Expected failures

- With integration disabled, `version --json` succeeds locally and `doctor --json` exits 9 in bounded time.
- An unknown action exits 3.
- A parameterized action, a parameter value, or `--timeout 0` exits 2 without executing an action.
- A CLI from another signing team or release channel is rejected by the broker.

See the [Phase 2 guide](cli-phase-2.md) for the complete command and exit-code matrix. Do not test destructive, privileged, privacy-sensitive, or disruptive actions merely to expand smoke coverage.
