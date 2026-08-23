# MacTools CLI

MacTools includes an authenticated local command-line client for discovering and
running the same canonical actions and workflows used by the app. The GUI host
remains the authority for availability, permissions, confirmation, concurrency,
timeouts, and plugin execution. The CLI does not load plugins itself.

## Setup

Open **Settings > General > Command Line** and choose **Install Command**. This
creates only `~/.local/bin/mactools`, as a symlink to the executable inside the
installed app. MacTools does not request administrator access or edit shell
startup files. Add `~/.local/bin` to `PATH` yourself if it is not already there.

The app also registers its bundled, user-scoped background broker. macOS may ask
for approval in **System Settings > General > Login Items & Extensions**. The
CLI starts the installed MacTools app without activation when the host is not
running and waits up to ten seconds for its action registry.

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

`--no-wait` is accepted only for actions that hand durable progress ownership to
MacTools. Ordinary actions wait for a terminal outcome. `SIGINT` and `SIGTERM`
request cancellation; the provider receives it only when its canonical action
declares cancellation support.

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
are validated again by the host and omitted from output and logs.

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

Remove the command from Settings to delete only the MacTools-owned symlink.
