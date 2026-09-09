# Test the downloadable Nightly CLI

MacTools Nightly publishes the experimental `mactools` CLI as a separate optional download. The CLI is not embedded in `MacTools Nightly.app` and does not increase the app download size. Use the app and CLI from the same [`nightly-*` prerelease](https://github.com/ggbond268/MacTools/releases) for this test.

The Nightly archive is a notarized ZIP named `mactools-cli-<version>-<build>-macos-arm64.zip`. It contains the signed `mactools` executable for Apple silicon Macs and the GPL-3.0-only `LICENSE`. Nightly CLI and stable CLI identities are intentionally separate; this prototype connects only to the Nightly app's broker.

## Download and verify

Download these four assets from one Nightly release:

- `MacTools-Nightly.dmg`
- `MacTools-Nightly.sha256`
- `mactools-cli-<version>-<build>-macos-arm64.zip`
- the matching `.zip.sha256`

From the download directory, replace the example archive name with the exact release asset name:

```bash
shasum -a 256 -c MacTools-Nightly.sha256
shasum -a 256 -c mactools-cli-1.2.1-123.1-macos-arm64.zip.sha256
CLI_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mactools-cli-test.XXXXXX")"
if ! ditto -x -k mactools-cli-1.2.1-123.1-macos-arm64.zip "$CLI_TEST_DIR"; then
  exit 1
fi
CLI_PATH="$CLI_TEST_DIR/mactools"
codesign --verify --strict --verbose=2 "$CLI_PATH"
codesign --display --verbose=4 "$CLI_PATH" 2>&1 \
  | grep -E '^(Identifier|Authority|TeamIdentifier)='
lipo -archs "$CLI_PATH"
```

The architecture output must contain exactly `arm64`. The signing identifier must end in `.mactools.nightly.cli`, the authority must be the MacTools Developer ID Application certificate, and the Team ID must match the Nightly app.

Do not use `spctl --assess --type execute` against the extracted `mactools` file as a notarization assertion. On macOS 26, `spctl` can reject a correctly signed standalone executable with `code is valid but does not seem to be an app`; that result describes the raw file shape, not whether the published ZIP passed notarization. Apple also documents that notarization tickets cannot currently be stapled to standalone binaries. The Nightly release workflow requires an `Accepted` notarization result for the exact CLI ZIP before publication, while this checklist independently verifies the downloaded checksum, Developer ID signature, identity, architecture, and actual execution. See [Apple's custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow#Staple-the-ticket-to-your-distribution).

Do not remove quarantine attributes or re-sign the executable if validation fails. Confirm that all files came from the same GitHub release, verify their checksums again, and report the release tag and validation output.

Keep the same terminal session open for the remaining snippets; they reuse the unique `CLI_TEST_DIR` and `CLI_PATH` values created above.

## Try the CLI without installing it

Install `MacTools Nightly.app` from the DMG and launch it once. In **Settings > Plugins > Marketplace**, install **Night Shift** from the Nightly catalog and wait until it is shown as installed. If `night-shift/toggle` does not appear after installation, relaunch MacTools Nightly once so the plugin can activate. Then, in **Settings > General > Command Line**, enable Command-Line Integration. Allow the MacTools Nightly background item in **System Settings > General > Login Items** if macOS requests approval.

Verify Gatekeeper acceptance against the installed app bundle:

```bash
spctl --assess --type execute --verbose=2 "/Applications/MacTools Nightly.app"
```

The result should be `accepted` with source `Notarized Developer ID`. Do not remove quarantine attributes or bypass Gatekeeper if this app assessment fails.

Use the extracted executable by absolute path first:

```bash
"$CLI_PATH" version --json
"$CLI_PATH" doctor --json
"$CLI_PATH" actions list --json
```

Copy complete action IDs from `actions list`; do not shorten or reconstruct them. To exercise and restore the harmless Night Shift toggle, record its current state and run:

```bash
"$CLI_PATH" actions describe night-shift/toggle --json
"$CLI_PATH" actions availability night-shift/toggle --json
"$CLI_PATH" actions run night-shift/toggle --timeout 15 --json
"$CLI_PATH" actions run night-shift/toggle --timeout 15 --json
```

Both runs should exit 0 and restore the recorded state. If either run fails, restore Night Shift manually in System Settings.

## Install on `PATH`

After the absolute-path checks pass, install the signed executable under a Nightly-specific name so an existing stable or source-built `mactools` command is never replaced:

```bash
mkdir -p "$HOME/.local/bin"
CLI_SOURCE="$CLI_PATH"
CLI_DEST="$HOME/.local/bin/mactools-nightly"
if [[ -e "$CLI_DEST" || -L "$CLI_DEST" ]]; then
  echo "mactools-nightly already exists; choose another test location" >&2
  exit 1
fi
if ! /usr/bin/python3 - "$CLI_SOURCE" "$CLI_DEST" <<'PY'
import os
import sys

try:
    os.symlink(sys.argv[1], sys.argv[2])
except OSError as error:
    raise SystemExit(f"refusing to replace CLI destination: {error}")
PY
then
  exit 1
fi
codesign --verify --strict --verbose=2 "$CLI_DEST"
"$CLI_DEST" doctor --json
```

The direct `symlink` system call fails atomically if any filesystem entry appears at the destination, including a directory or dangling symlink. Keep the extracted directory while using the command. Add `$HOME/.local/bin` to `PATH` if needed. In the same download directory, remove only a link that still targets the extracted CLI used above:

```bash
CLI_SOURCE="$CLI_PATH"
CLI_DEST="$HOME/.local/bin/mactools-nightly"
if [[ -L "$CLI_DEST" && "$(readlink "$CLI_DEST")" == "$CLI_SOURCE" ]]; then
  rm "$CLI_DEST"
else
  echo "refusing to remove an entry not created for this extracted Nightly CLI" >&2
  exit 1
fi
```

Disable Command-Line Integration before removing MacTools Nightly. The CLI and app may be upgraded independently when their negotiated protocol ranges overlap, but testing the same Nightly release removes avoidable compatibility uncertainty.

## Expected failures

- With integration disabled, `version --json` succeeds locally and `doctor --json` exits 9 in bounded time.
- An unknown action exits 3.
- A parameterized action, a parameter value, or `--timeout 0` exits 2 without executing an action.
- A CLI from another signing team or release channel is rejected by the broker.

See the [Phase 2 guide](cli-phase-2.md) for the complete command and exit-code matrix. Do not test destructive, privileged, privacy-sensitive, or disruptive actions merely to expand smoke coverage.
