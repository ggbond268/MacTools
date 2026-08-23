# MacTools CLI

MacTools provides an optional authenticated local command-line client for discovering and
running the same canonical actions and workflows used by the app. The GUI host
remains the authority for availability, permissions, confirmation, concurrency,
timeouts, and plugin execution. The CLI does not load plugins itself.

## Setup

Download `mactools-cli-<version>-macos-universal.zip` and its `.sha256` file from
the same [GitHub release](https://github.com/ggbond268/MacTools/releases) as the
installed app. The archive contains one universal executable named `mactools`.
Install it in a user-owned directory:

```bash
mkdir -p "$HOME/.local/bin"
unzip mactools-cli-*-macos-universal.zip
install -m 755 mactools "$HOME/.local/bin/mactools"
```

MacTools does not request administrator access or edit shell startup files. Add
`~/.local/bin` to `PATH` yourself if it is not already there.

Open **Settings > General > Command Line** and enable the integration. The app
then registers its bundled, user-scoped background broker. Merely installing the
app or CLI does not register it. macOS may ask
for approval in **System Settings > General > Login Items & Extensions**. The
CLI starts the installed MacTools app without activation when the host is not
running and waits up to ten seconds for discovery, launch, broker replacement,
and action-registry registration. Cancelling the CLI also stops waiting for host
discovery immediately.

If more than one MacTools copy is registered, the CLI checks every Launch
Services candidate, requires the same release version and build plus the exact
same-team host signature, and then chooses deterministically. `doctor --json`
reports distinct categories for a missing or mismatched app, an invalid
signature, a launch failure, and background-item approval instead of reducing
all cold-start failures to one timeout. When the enabled app path or release
changes, MacTools refreshes its broker registration before reconnecting, so a
previous broker cannot keep a newly installed matching CLI on the old release.

The app and CLI use the same release version initially, but remain separate
artifacts so either can be replaced independently. Their handshake selects the
highest mutually supported protocol version and fails clearly if none overlaps.
Disable the integration in Settings to unregister the broker. Remove the CLI
executable yourself when it is no longer needed.

## Commands

```text
mactools version [--json]
mactools doctor [--json]
mactools actions list [--runnable] [--page-token token] [--json]
mactools actions describe <provider/action> [--json]
mactools actions availability <provider/action> [--json]
mactools actions run <provider/action> [--parameter name=value ...]
    [--input-json <path|->] [--no-wait] [--json]
mactools workflows list [--page-token token] [--json]
mactools workflows describe <name-or-uuid> [--json]
mactools workflows run <name-or-uuid> [--no-wait] [--json]
mactools plugins list [--page-token token] [--json]
mactools plugins describe <plugin-id> [--json]
mactools plugins doctor <plugin-id> [--json]
```

Workflow names resolve only when there is one exact match. Action identity is
always the stable `provider/action` key printed by `actions list`.

One action definition may publish several parameter presets to graphical action
surfaces. CLI discovery still emits one record for its stable key, using the
definition's title, description, parameter schema, and capabilities. Its
availability and CLI eligibility are true when at least one published preset is
available or eligible. Execution always validates the caller's submitted
parameters and rechecks availability and exposure for that exact reference.

`--no-wait` is accepted only for actions that hand durable progress ownership to
MacTools. Ordinary actions wait for a terminal outcome. `SIGINT` and `SIGTERM`
request cancellation; the provider receives it only when its canonical action
declares cancellation support. The CLI exits with status `8` after forwarding
the interrupt, including during host startup, parameter discovery, confirmation,
and the request-admission boundary.

Saved Scripts propagates an opaque invocation marker to child processes. If a
script invokes `mactools` again while its parent CLI request is active, the
broker rejects the nested request as recursive. Invocation markers are bounded,
never printed, and are not credentials; the normal global request and action
concurrency limits remain in force.

## Parameters and secrets

Public string, integer, number, and Boolean parameters may use repeated
`--parameter name=value` arguments. Sensitive parameters are rejected on the
command line because process arguments are visible to other local tools.

Use JSON on standard input or in a protected file instead:

```bash
printf '%s\n' '{"token":"secret"}' |
  mactools actions run provider/action --input-json -

mactools actions run provider/action --input-json "$HOME/private-input.json"
```

A file must be a regular, non-symlink file owned by the current user, have no
group or other permission bits, and fit within the 64 KiB request limit. Values
are decoded against the current action schema, validated again by the host, and
omitted from output and logs. JSON Booleans are not accepted as numbers (or vice
versa); integer and number parameters retain their declared schema types.

## JSON and exit status

`--json` writes exactly one versioned object. It includes `schemaVersion`,
`protocolVersion`, `requestID`, `command`, timestamps, `invocationSource`,
`outcome`, a structured `rejection`, and command-specific `data`.

| Exit | Meaning |
| ---: | --- |
| 0 | Completed or durably started |
| 2 | Invalid command or parameters |
| 3 | Unknown action, workflow, or plugin |
| 4 | Known but unavailable |
| 5 | Confirmation denied or unavailable |
| 6 | Provider/action failure |
| 7 | Timed out |
| 8 | Cancelled |
| 9 | Host or broker transport failure |
| 10 | Incompatible protocol |

## Trust boundary

Release builds require the CLI, broker, and GUI host to have exact role-specific
signing identifiers, the same Developer Team identifier, valid strict code
signatures, and the same effective user. The broker does not discover plugins,
persist payloads, or execute actions.

Disabling Command-Line Integration unregisters the broker but does not modify the
separately installed CLI executable.
