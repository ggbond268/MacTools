# CLI Phase 0 test guide

Phase 0 is a development prototype for validating the command-line transport before action discovery or execution is added. The CLI is a separate build product; `MacTools.app` contains only the opt-in broker needed to reach the running host.

## Supported commands

```text
mactools help
mactools version [--json]
mactools doctor [--json]
```

Actions, workflows, plugins, parameters, and public CLI release packaging are deliberately out of scope.

## Build locally

Complete the normal `make setup` signing configuration, then run:

```bash
make build
make build-cli
```

The Debug executable is written to:

```text
build/DerivedData/Build/Products/Debug/mactools
```

Use that absolute path directly:

```bash
/absolute/path/to/MacTools/build/DerivedData/Build/Products/Debug/mactools help
/absolute/path/to/MacTools/build/DerivedData/Build/Products/Debug/mactools version --json
/absolute/path/to/MacTools/build/DerivedData/Build/Products/Debug/mactools doctor --json
```

For a convenient local command, create a symlink outside the app bundle:

```bash
mkdir -p "$HOME/.local/bin"
ln -sfn "/absolute/path/to/MacTools/build/DerivedData/Build/Products/Debug/mactools" "$HOME/.local/bin/mactools"
"$HOME/.local/bin/mactools" doctor --json
```

## First-use flow

1. Run the signed Debug app once.
2. Open Settings > General > Command Line.
3. Enable the integration.
4. If macOS reports that approval is required, allow the MacTools background item in System Settings > General > Login Items.
5. Quit the app, then run `doctor --json`. The broker should launch MacTools without activating a window, wait for host readiness, and return a completed response.

`version` is intentionally local-first: it succeeds when the broker is unavailable and never requests a host launch. `doctor` uses a monotonic 10-second startup deadline and returns exit code 9 instead of waiting indefinitely when the broker or host is unavailable.

## Acceptance matrix

Record the exact app, broker, and CLI signatures plus each command's output and exit code.

| Scenario | Expected result |
| --- | --- |
| Integration disabled | `version` succeeds; `doctor` exits 9 with enable/approval guidance. |
| Integration enabled, app running | `doctor` succeeds and reports host, broker, protocol, and service status. |
| Integration enabled, app closed | `doctor` cold-launches the host and succeeds within 10 seconds. |
| Background item requires approval | Settings links to Login Items; `doctor` fails in bounded time. |
| Different product versions, overlapping protocol range | Connection succeeds because product versions are informational. |
| Non-overlapping protocol ranges | Command exits 10 with `protocolIncompatible`. |
| Wrong user, Team ID, or signing role | XPC admission is rejected. |
| Duplicate IDs or more than 8 client / 32 global requests | Broker rejects admission without forwarding to the host. |
| SIGINT or SIGTERM during `doctor` | CLI requests cancellation and exits 8. |
| App or broker upgrade while enabled | Registration is replaced using the new app path/version fingerprint. |

Before moving the prototype PR out of draft, repeat the signed end-to-end scenarios on macOS 14, macOS 15, and the current macOS release.
