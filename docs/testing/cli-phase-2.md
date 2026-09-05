# CLI Phase 2 implementation and test checklist

Phase 2 adds narrow action execution to the separately built development CLI. Follow the [Phase 2 contract](../superpowers/specs/2026-08-30-cli-phase-2-execution.md) and the [Phase 0 setup guide](cli-phase-0.md) for signed local installation. This is prototype evidence, not public-release readiness.

## Clean-machine contributor smoke test

Use a local Debug app, broker, and CLI built from the same checkout with the same development team. The prototype CLI will not authenticate against an arbitrary Stable, Nightly, or differently signed development app.

### 1. Configure the checkout

Install the normal repository prerequisites, including Xcode and XcodeGen. From the repository's default branch, initialize local configuration before switching to a feature branch or pull-request commit:

```bash
make setup
```

Set both values in the ignored `LocalConfig.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
BUNDLE_IDENTIFIER_PREFIX = your.unique.reverse.dns.prefix
```

The app, embedded broker, and standalone CLI must use this same team and prefix. If the desired branch is already checked out, do not rerun `make setup`, because it also initializes the local branch name; create `LocalConfig.xcconfig` from `LocalConfig.sample.xcconfig` instead.

### 2. Build the app, CLI, and one harmless test plugin

```bash
make build
make build-cli
make build-plugin PLUGIN=NightShift
make run PLUGIN=NightShift
```

`make run` installs the matching app at `~/Applications/MacTools Dev.app`, installs only the selected local plugin package, and stays attached until the app exits. Leave it running and use a second terminal, opened at the same repository root, for the remaining commands. On a machine with an existing `MacTools Dev.app`, preserve that installation or use a separate development account instead of replacing it.

### 3. Enable the broker and verify readiness

In **MacTools Dev > Settings > General > Command Line**, enable Command-Line Integration. If macOS asks for approval, allow the MacTools background item in **System Settings > General > Login Items**.

Use the standalone product at its absolute checkout path; do not use a `mactools` binary from another build:

```bash
"$PWD/build/DerivedData/Build/Products/Debug/mactools" version --json
"$PWD/build/DerivedData/Build/Products/Debug/mactools" doctor --json
"$PWD/build/DerivedData/Build/Products/Debug/mactools" actions list --json
```

`doctor` should report a completed request using protocol version 3. Copy IDs from the current `actions list` response instead of shortening, guessing, or reconstructing them.

### 4. Exercise and restore Night Shift

Record the current Night Shift state in System Settings before executing the action. Confirm that the exact parameterless ID `night-shift/toggle` appears in the current list, then run it twice:

```bash
"$PWD/build/DerivedData/Build/Products/Debug/mactools" \
  actions describe night-shift/toggle --json
"$PWD/build/DerivedData/Build/Products/Debug/mactools" \
  actions availability night-shift/toggle --json
"$PWD/build/DerivedData/Build/Products/Debug/mactools" \
  actions run night-shift/toggle --timeout 15 --json
"$PWD/build/DerivedData/Build/Products/Debug/mactools" \
  actions run night-shift/toggle --timeout 15 --json
```

Both executions should exit 0. Verify that Night Shift returned to its recorded state. If either command is interrupted or fails, or if the final state differs from the recorded state, restore the recorded state manually in System Settings before continuing.

### 5. Check bounded rejection paths

These commands must not execute a system action:

```bash
"$PWD/build/DerivedData/Build/Products/Debug/mactools" \
  actions run missing/action --json
echo "exit=$?" # expected: 3

"$PWD/build/DerivedData/Build/Products/Debug/mactools" \
  actions run night-shift/toggle --timeout 0 --json
echo "exit=$?" # expected: 2
```

Also copy one complete `night-shift/set-enabled@…` ID from `actions list` and pass it to `actions run`; Phase 2 must reject that parameterized reference with exit 2. Do not test timeout or cancellation by invoking a destructive, privileged, privacy-sensitive, or disruptive real action; the fake-provider XCTest coverage is the acceptance evidence for those paths.

### 6. Finish and clean up

Disable Command-Line Integration before removing the development app. Quit MacTools Dev or press Control-C in the terminal running `make run`, then confirm that `doctor --json` fails in bounded time rather than hanging. Remove the development app and its application-support data only if they were created solely for this test; do not remove or overwrite another contributor's existing development installation.

## Sample commands

Use an absolute path or a separately installed `mactools` on `PATH`. Always copy the complete ID from the current list output:

```bash
mactools doctor --json
mactools actions list --json
mactools actions describe 'ID-FROM-LIST' --json
mactools actions availability 'ID-FROM-LIST' --json
mactools actions run 'EXECUTION-SUPPORTED-ID' --json
mactools actions run 'EXECUTION-SUPPORTED-ID' --timeout 15
```

Negative and cancellation checks:

```bash
mactools actions run missing/action --json
mactools actions run 'PARAMETERIZED-ID' --json
mactools actions run 'EXECUTION-SUPPORTED-ID' --timeout 0 --json
mactools actions run 'EXECUTION-SUPPORTED-ID' --parameter value=x --json
mactools actions run 'LONG-RUNNING-ID' --timeout 1 --json
mactools actions run 'LONG-RUNNING-ID' --timeout 60 --json
# Press Ctrl-C during the last command.
```

Confirm success exits 0; malformed/ineligible input 2; unknown targets 3; unavailable/busy actions 4; provider failure 6; timeout 7; cancellation 8; host/transport failure 9; and protocol mismatch 10. JSON failures go to stdout and human failures to stderr.

## Required coverage

- Protocol v3 negotiation while v1 doctor and v2 discovery remain compatible.
- Strict request/result shapes, timeout bounds, response identity, outcome/payload/rejection combinations, and human/JSON rendering.
- Exact current discovery IDs only; parameter declarations, parameterized references, preset workflow steps, exclusions, unsafe actions, foreground-only actions, non-automatic actions, non-portable references, and guessed IDs fail closed.
- Fresh availability, provider revision, catalog publication, exposure, concurrency, and eligibility revalidation immediately before admission.
- Provider failure messages and private availability reasons do not reach output; bounded sanitized success text does.
- Timeout and SIGINT cancel the host task and action handle without retrying uncertain delivery.
- Focused XCTest classes: `CLIActionRunnerTests`, `CLIActionDiscoveryTests`, `CLIDiscoveryProtocolTests`, `CLIArgumentParserTests`, `CLIHostRequestStateTests`, `CLIHostDiscoveryTests`, `CLIExecutableTests`, and existing action-executor/transport/security tests.
- Run `make ci`, including script tests, changelog validation, the full XCTest suite, and PluginKit v5 binary compatibility.
- Use isolated, development-signed Phase 2 app/broker/CLI identities on macOS 26 and 27. Verify signatures, hot/cold launch, doctor, discovery, one harmless real action, negative cases, timeout/cancellation where a harmless long-running action exists, and that no existing MacTools installation is stopped or overwritten.

Do not execute destructive, privileged, privacy-sensitive, or user-disruptive actions merely to expand smoke coverage. Unit-level fake providers are the acceptance evidence for timeout/cancellation if no harmless real action can exercise those paths. macOS 14/15 and public packaging remain separate follow-ups.
