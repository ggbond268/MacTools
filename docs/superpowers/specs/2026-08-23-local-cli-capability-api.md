# Local CLI and Capability API

**Status:** Proposed decision for [issue #309](https://github.com/ggbond268/MacTools/issues/309)

## Decision Summary

MacTools should ship an official `mactools` command-line tool. The CLI is a
local, authenticated client of the running MacTools host; it is not a second
plugin host and it does not introduce a network API.

The first implementation will use a user-scoped bundled LaunchAgent as a narrow
XPC broker:

```text
signed mactools CLI
        |
        | versioned, mutually authenticated XPC
        v
launchd-managed MacTools CLI broker
        |
        | versioned, mutually authenticated XPC
        v
primary MacTools GUI host
        |
        v
ActionRegistry -> ActionExecutor -> registered provider
```

The following decisions are part of the first contract:

- Canonical actions remain the sole execution domain model.
- The GUI host remains authoritative for plugins, workflows, availability,
  confirmation, concurrency, timeout, cancellation, and results.
- Run Links remain supported and keep their current lightweight role.
- CLI execution initially reuses `ActionExternalInvocationPolicy` and adds a
  provider veto through `ActionExposureSurface.cli`.
- The host starts without activation when the CLI needs it. UI is raised only
  when the selected action or confirmation flow requires it.
- Public parameters may be supplied on the command line. Sensitive parameters
  are accepted only from standard input or a tightly permissioned input file.
- The CLI ships inside `MacTools.app`; Homebrew exposes the bundled binary and
  the app can install a user-owned `~/.local/bin/mactools` symlink.
- The initial protocol is private to the bundled app and CLI. It is versioned,
  but it is not yet a supported third-party API.

## Product Role

The CLI is an additional invocation and discovery surface over the action
platform described in `docs/actions-automation.md`. It is intended for local
scripts, shell aliases, developer tools, launchers, test automation, support
diagnostics, and future local agent adapters.

It does not replace Run Links. Run Links remain the compact choice for clickable
integrations, Apple Shortcuts, launchers, and fire-and-forget commands that do
not need structured input or a result. The CLI is the choice when the caller
needs discovery, typed parameters, completion, cancellation, machine-readable
output, or stable exit behavior.

## Goals

- Discover the canonical actions and workflows that the current host has
  actually registered.
- Describe parameter schemas, availability, and CLI eligibility without loading
  plugin bundles in the CLI or broker.
- Invoke eligible actions through `ActionExecutor` and preserve every existing
  policy check.
- Return bounded, versioned, redacted results in human-readable or JSON form.
- Start the installed host when necessary and wait for registry readiness with
  a fixed deadline.
- Authenticate the user and code-signing identity at every process boundary.
- Survive compatible app/CLI/broker upgrade ordering and fail clearly when
  versions are incompatible.

## Non-Goals

- TCP, HTTP, REST, WebSocket, or any other network listener
- remote control or multi-user control
- loading or inspecting plugin bundles outside the host
- arbitrary Swift, Objective-C selector, shell, or plugin-internal invocation
- replacing the GUI, Run Links, App Intents, or Apple Shortcuts
- root, privileged-helper, or system-wide installation
- plugin installation, updates, or removal from the first CLI
- headless guarantees for actions that need a graphical session
- a permanently stable public protocol for third-party clients
- progress-event streaming in protocol version 1

## Transport Decision

### Selected: bundled user LaunchAgent with XPC

The app bundles a small broker executable and a LaunchAgent property list under
`Contents/Library/LaunchAgents`. The app registers it with
`SMAppService.agent(plistName:)`. The LaunchAgent advertises one Mach service in
the current user's launchd domain and starts on demand.

The broker has no action definitions or plugin knowledge. It performs four
jobs only:

1. authenticate CLI and host connections;
2. negotiate the private protocol version;
3. bound and correlate request, response, and cancellation envelopes; and
4. route accepted requests to the currently registered primary host.

The primary host opens a bidirectional connection to the broker after its action
registry and workflow provider are ready. It exports a host interface on that
connection. The broker retains the connection only while it is live and never
persists a host endpoint or action payload.

The CLI connects to the broker's Mach service. If the service or host is not
ready, the CLI locates and launches the containing MacTools app, then retries
the handshake until the startup deadline. The existing `CFMessagePort` single-
instance channel remains limited to launch/reopen/deep-link forwarding and is
not extended into a capability API.

Apple documents `SMAppService` as the macOS 13+ mechanism for registering
LaunchAgents bundled in an app, and `NSXPCConnection(machServiceName:)` as the
connection form for a Mach service advertised by a LaunchAgent:

- <https://developer.apple.com/documentation/servicemanagement/smappservice>
- <https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)>
- <https://developer.apple.com/documentation/foundation/nsxpcconnection>

### Why the other candidates are not selected

| Criterion | LaunchAgent XPC | GUI-owned endpoint | Unix-domain socket |
| --- | --- | --- | --- |
| Discovery | launchd Mach service | endpoint publication file | socket path |
| Host not running | broker can remain discoverable and CLI can launch host | stale/missing endpoint bootstrap | stale/missing socket bootstrap |
| Same-team validation | XPC code-signing requirement | possible, but endpoint origin still needs secure bootstrap | custom peer audit/signing validation |
| Same-user validation | user launchd domain plus peer EUID check | peer EUID check | file mode plus peer credentials |
| Cancellation | bidirectional request | bidirectional request | custom framing and state |
| Upgrade/removal | `SMAppService` registration lifecycle | custom endpoint cleanup | custom socket cleanup |
| Testability | injectable broker/host protocols | injectable endpoint store and protocols | custom server and framing harness |
| Custom security code | limited | endpoint authenticity and stale-file handling | highest |

A GUI-owned anonymous XPC endpoint removes one process, but safely publishing,
replacing, and authenticating the endpoint recreates much of a service manager.
A Unix-domain socket provides useful streaming semantics, but protocol framing,
peer identity, file permissions, stale socket recovery, and signature checking
would all become MacTools-owned security code. The broker architecture is more
work than a prototype socket, but has the clearest lifecycle and smallest custom
trust surface.

## Trust and Security Model

### Process identities

Release builds use three distinct signing identifiers under the configured
bundle prefix:

- GUI host: `$(BUNDLE_IDENTIFIER_PREFIX).mactools`
- CLI: `$(BUNDLE_IDENTIFIER_PREFIX).mactools.cli`
- broker: `$(BUNDLE_IDENTIFIER_PREFIX).mactools.cli-broker`

Debug builds use the corresponding `.mactools.dev` identities. The concrete
identifiers are generated into build settings; they are not inferred from an
untrusted request.

Every accepted connection must satisfy all of these checks:

- its effective user ID equals the broker or client's effective user ID;
- its code signature is valid and has the expected exact signing identifier;
- its Team Identifier equals the broker's Team Identifier;
- the dynamic code instance satisfies its designated requirement; and
- validation failure or unavailable identity information rejects the connection.

The broker listener applies an exact connection code-signing requirement before
its delegate accepts a host or CLI connection. The listener then verifies EUID
and assigns the connection one fixed role based on its signing identifier. A
host connection cannot call CLI methods and a CLI connection cannot register as
the host.

The host and CLI validate the connected broker while the connection is alive,
using the peer process identity and Security framework dynamic-code checks. On
macOS 14.4 and later, the implementation should additionally apply XPC's peer
code-signing requirement API. macOS 14.0 through 14.3 retain the explicit
Security framework validation so the project does not need to raise its current
deployment target.

Apple's Security framework supports resolving a running guest by audit or
process attributes, and XPC can enforce peer signing requirements before
delivering messages:

- <https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)>
- <https://developer.apple.com/documentation/security/guest-attribute-dictionary-keys>
- <https://developer.apple.com/documentation/updates/xpc>

### Authorization is not action admission

A valid signature authorizes a process to speak the private protocol. It never
authorizes an action by itself. The host still resolves every reference through
`ActionRegistry` and executes only through `ActionExecutor`.

The host must revalidate, in order:

1. protocol and request shape;
2. catalog publication and current registration;
3. schema version and typed parameters;
4. CLI exposure and external-invocation policy;
5. current availability and execution-mode support;
6. confirmation policy;
7. provider generation, execution revision, and availability after confirmation;
8. concurrency policy; and
9. the action's configured timeout and cancellation capability.

The existing pre-execution revalidation in `ActionExecutor` remains the final
gate. The CLI bridge must not call provider closures directly.

### Bounds and redaction

Protocol version 1 uses these hard bounds:

- request envelope: 64 KiB
- typed action parameters: existing `ActionParameterSet` limits, including a
  16 KiB aggregate value limit
- response envelope: 4 MiB
- discovery page: at most 256 records; a continuation token is required for
  additional records
- in-flight requests per CLI connection: 8
- in-flight CLI requests globally: 32
- inherited CLI invocation depth: 1
- pending pre-admission cancellations per CLI connection: 8
- request identifier: UUID generated by the CLI
- host startup and registry readiness: 10 seconds total

The broker may inspect the fixed envelope header needed for routing and bounds,
but it must not log payload data. The host and CLI log only request ID, command,
action key, duration, and redacted outcome category. Parameter values never
appear in diagnostics, audit entries, JSON output, history, or error messages.
Before returning provider-owned messages, the host bridge replaces exact string
representations of supplied values with a redaction marker. Providers remain
responsible for returning user-facing messages that do not disclose secrets;
the bridge redactor is a final containment layer, not permission to echo input.

The decoder rejects unsupported protocol versions, unknown operation names,
missing fields, duplicate fields, invalid enum values, and payloads over the
limit. Adding an optional field requires a protocol-version decision; silently
accepting unknown JSON keys is not part of the contract.

Protocol version 1 in this document is the first unreleased wire draft; no
released MacTools build advertises it. `invocationContext` is therefore part of
the v1 schema before that schema is frozen, while its optional decoding permits
requests produced by earlier prototype clients. Earlier development-branch
brokers and hosts are not supported upgrade peers. The first public CLI release
freezes this shape: any later request-header field requires a new negotiated
protocol version, and a broker must encode only fields supported by the selected
host version.

## Protocol Shape

Protocol version 1 is a request/reply protocol with a separate cancellation
message. XPC carries `Data` values containing strict Codable envelopes so the
wire schema can be fuzzed and versioned independently of Swift or Objective-C
method layouts.

Each request header contains:

```json
{
  "protocolVersion": 1,
  "requestID": "7A2775DB-ACF1-4A95-A04B-C6F41E42C277",
  "operation": "actions.run",
  "sentAt": "2026-08-23T18:42:30.123Z",
  "invocationContext": null,
  "payload": {}
}
```

The CLI omits `invocationContext` for a root invocation. The broker replaces it
with a newly generated opaque chain UUID and depth `0` before forwarding the
request to the host. A shared command runner may pass that chain to a child
process through `MACTOOLS_CLI_CHAIN_ID` and `MACTOOLS_CLI_CHAIN_DEPTH`, with the
depth incremented to `1`. A child CLI sends the inherited context back to the
broker. The broker rejects active chains as recursive and rejects malformed,
expired, unknown, or deeper contexts as invalid input. Chain values are routing
metadata and must not be logged or returned in command output.

The handshake exchanges:

- minimum and maximum supported protocol versions;
- CLI, broker, and host marketing/build versions;
- the selected protocol version;
- host registration/readiness state; and
- a redacted incompatibility or startup failure category.

Requests are idempotent only where explicitly documented. Discovery and doctor
requests are idempotent. `actions.run` and `workflows.run` are not automatically
retried after the broker has acknowledged forwarding; an uncertain transport
result fails with `hostTransportFailure` rather than risk duplicate execution.

The host tracks each running request by request ID. `cancel` cancels the host
task and calls the provider cancellation handler only when the canonical action
declares `.cancellable`. A cancellation that reaches the broker immediately
before request admission is retained in a per-connection bounded set and
consumed when that request arrives. After admission, the broker orders
`host.handle` before any corresponding `host.cancel`; the host also retains a
bounded cancellation received before its main-actor request task is registered.
`SIGINT` and `SIGTERM` cover the entire remote-command lifecycle, including host
startup and parameter-schema discovery. They are handled once per CLI request,
restore the process's prior signal dispositions afterward, and wait for
cancellation forwarding before the CLI emits exit `8`. Disconnecting a CLI
cancels requests that have not yet been durably accepted. A continuing action
that has already returned `started` keeps its host-owned progress UI and is not
canceled by client disconnect.

Fine-grained progress is deferred. Protocol version 1 reports only accepted,
started, and terminal states.

## Action Exposure and Eligibility

Add these model values to `MacToolsPluginKit`:

```swift
public extension ActionExposureSurface {
    static let cli = ActionExposureSurface(rawValue: "cli")
}

public extension ActionExecutionSource {
    static let cli = ActionExecutionSource(rawValue: "cli")
}
```

`ActionExecutionSource` is currently a public enum in PluginKit v5. Phase 2 must
therefore introduce PluginKit v6, rebuild every plugin, and convert the source
to a string-backed `RawRepresentable` value like `ActionExposureSurface`. Its
existing raw strings remain unchanged. This is one intentional ABI migration
that allows future host-owned invocation sources to be added without repeatedly
making provider switches exhaustive.

An action is visible in CLI discovery when it has a published catalog entry.
Visibility does not imply that the action can run. `actions list` includes
unavailable and excluded actions with a structured `cliEligibility` state;
`--runnable` filters them for interactive use. An unpublished provider action
is not exposed.

An action can run from the CLI only when all of the following are true:

- its catalog entry is published and currently registered;
- its reference migrates to the current schema and all parameters validate;
- its availability is currently true;
- the host can choose a supported execution mode;
- `externalInvocationPolicy` is not `.unavailable`;
- the provider's policy for `ActionExposureSurface.cli` is not `.excluded`;
- sensitive values arrived through an allowed input path; and
- the normal confirmation, concurrency, provider-generation, and timeout gates
  succeed.

Version 1 deliberately reuses `ActionExternalInvocationPolicy` as the broad
external opt-in. `.confirmAlways` applies to both Run Links and CLI requests.
`ActionExposureSurface.cli` lets a provider narrow that opt-in without creating
a second broad policy. A future CLI-only opt-in can be added only after real
actions demonstrate a need to be callable by a signed local client but not by a
Run Link.

The host prefers background execution when the action supports it, otherwise it
uses foreground execution. Foreground-only or confirmation-required actions
may activate the host to present UI. If there is no graphical login session or
the host cannot present confirmation, execution fails; it is never approved
silently.

`--no-wait` is accepted only for an action that publishes durable progress with
`.reportsProgress`. It returns `started` after validation and confirmation. For
all other actions it is invalid input. Ordinary actions wait for a terminal
result and keep the action's configured timeout.

## Sensitive Parameter Input

`--parameter name=value` accepts public parameters only. Before sending an
invocation, the CLI fetches the current description and rejects this syntax for
any parameter whose privacy is `.sensitive`.

`--input-json -` reads typed values from standard input. A file path is accepted
only when the CLI can open it without following a symlink and `fstat` confirms
that it is:

- a regular file;
- owned by the current effective user;
- inaccessible to group and other users (no `0077` permission bits); and
- within the request-size bound.

Before decoding JSON values, the CLI fetches the current action description and
uses its parameter schema as the type authority. Boolean, integer, number, and
string values cannot cross-convert merely because Foundation bridges their
runtime representations; integer bounds are checked exactly.

The file path may appear in process arguments, but its contents do not. The CLI
reads once from the verified descriptor and does not reopen by path. Sensitive
values are held only for request encoding and are cleared with the request
lifetime as far as Swift value semantics allow. A future host-owned secure
prompt or Keychain preset can extend this model without putting secrets in
arguments.

The host independently checks parameter privacy metadata. It never returns an
invocation reference containing parameter values. Public and sensitive values
are both omitted from stdout JSON, logs, diagnostics, workflow history, and
optional audit entries.

## Command Contract

The first released CLI includes:

```text
mactools help
mactools version [--json]
mactools doctor [--json]

mactools actions list [--runnable] [--json]
mactools actions describe <provider/action> [--json]
mactools actions availability <provider/action> [--json]
mactools actions run <provider/action> [--parameter name=value ...]
    [--input-json <path|->] [--no-wait] [--json]

mactools workflows list [--json]
mactools workflows describe <name-or-id> [--json]
mactools workflows run <name-or-id> [--no-wait] [--json]

mactools plugins list [--json]
mactools plugins describe <plugin-id> [--json]
mactools plugins doctor <plugin-id> [--json]
```

`workflows run` resolves the name or UUID to the workflow's canonical
`automation/workflow.<uuid>` action and invokes it through `ActionExecutor`.
Workflow list and describe are convenience discovery operations over the host's
workflow store and published actions; they do not create a second execution
path. Ambiguous workflow names fail and print the matching IDs.

Plugin commands are read-only snapshots from `PluginHost`. `plugins doctor`
reports installation, compatibility, trust, load, permission, and action-
provider status. Installation, update, enable/disable, and removal are excluded.

`workflows history` is deferred until the history privacy and pagination
contract is designed in a later protocol version. Progress streaming and MCP
are also deferred.

Human-readable output is concise, localized using the current process locale,
and written to stdout on success. Diagnostics and errors go to stderr. JSON mode
emits exactly one UTF-8 JSON object to stdout and no decorative text.

`mactools version` always reports the bundled CLI and containing-app versions
without launching the host. If a broker and host are already reachable it also
reports their selected protocol and runtime builds. `mactools doctor` performs
the active registration, launch, identity, readiness, and compatibility checks.

## JSON Output Contract

Every `--json` response uses this top-level envelope:

```json
{
  "schemaVersion": 1,
  "protocolVersion": 1,
  "requestID": "7A2775DB-ACF1-4A95-A04B-C6F41E42C277",
  "command": "actions.run",
  "actionReference": {
    "providerID": "display.brightness",
    "actionID": "increase",
    "schemaVersion": 1
  },
  "invocationSource": "cli",
  "startedAt": "2026-08-23T18:42:30.123Z",
  "finishedAt": "2026-08-23T18:42:30.287Z",
  "outcome": "completed",
  "message": "Brightness increased.",
  "rejection": null,
  "data": null
}
```

The stable version-1 outcome values are:

- `completed`
- `started`
- `cancelled`
- `unavailable`
- `confirmationDenied`
- `timedOut`
- `invalidInput`
- `unknownTarget`
- `failed`
- `hostUnavailable`
- `providerChanged`
- `protocolIncompatible`

`rejection`, when present, has a stable `category` plus an optional redacted,
user-facing `message`. It never contains a raw Swift error, provider object,
path from a sensitive value, or parameter value. `data` contains a command-
specific versioned object for discovery and doctor commands. List responses
include a continuation token when another page exists.

Timestamps use UTC RFC 3339 with millisecond precision. `finishedAt` is `null`
only for `started`. `actionReference` is omitted for commands that do not target
an action and never includes parameters.

## Exit Codes

These numeric categories are stable for CLI major version 1:

| Code | Category | Examples |
| ---: | --- | --- |
| 0 | success | completed discovery/action, or durable work accepted as `started` |
| 2 | invalid command or input | usage, duplicate parameter, wrong type, insecure input file |
| 3 | unknown target | unknown action, workflow, or plugin |
| 4 | unavailable | unavailable action, unsupported mode, external/CLI exposure excluded, concurrency rejection |
| 5 | confirmation failure | confirmation denied or UI unavailable |
| 6 | action failure | provider failure or provider changed during admission/execution |
| 7 | timeout | confirmation or action execution timeout |
| 8 | cancellation | caller interrupt or provider cancellation |
| 9 | host or transport failure | app missing, startup failure, broker unavailable, authentication failure, uncertain delivery |
| 10 | protocol incompatibility | no overlapping protocol version or invalid peer contract |

Shell parse failures happen before a request ID exists. JSON mode still returns
the same envelope with a locally generated request ID and `protocolVersion: null`
when negotiation never occurred.

## Host Lifecycle

For discovery, doctor, and execution commands, startup proceeds as follows:

1. Resolve the real CLI executable path and verify its containing app bundle.
2. Prefer that containing app; otherwise query Launch Services by the expected
   release or debug bundle identifier.
3. Verify the app's signing identifier and Team Identifier before launching it.
4. Connect to the broker and negotiate. If the broker is not registered or the
   host is absent, launch the app without activation and retry.
5. The existing single-instance coordinator ensures only the primary host
   initializes the runtime.
6. The primary host gives every `PluginActionCatalogPreparing` provider a
   bounded preparation window, then synchronously rebuilds `ActionRegistry` and
   publishes workflow actions before registering with the broker. A stalled
   provider is logged and omitted from the prepared snapshot. Readiness does not
   depend on a fixed delay; if the provider later completes normally, the Host
   republishes that provider without requiring a restart.
7. Retry with jitter inside one 10-second deadline. Do not reset the deadline
   after a partial handshake.
8. Return a precise startup, approval-required, authentication, or compatibility
   error on failure.

If `SMAppService` reports that user approval is required, `doctor` identifies
the broker as disabled and gives the System Settings path. The implementation
does not fall back to an unauthenticated socket or the instance-coordination
port.

No graphical login session means discovery may proceed if the host is already
available, but launching the GUI host or presenting confirmation can fail with
a clear host/confirmation category.

## Distribution and Shell Path

The signed universal CLI binary is embedded at:

```text
MacTools.app/Contents/MacOS/mactools
```

Keeping it in `Contents/MacOS` gives the binary a stable relationship to the
containing app and its embedded resources. The broker is a separate auxiliary
executable referenced by the bundled LaunchAgent property list.

Apple's command-line-tool embedding guidance identifies `Contents/MacOS` as a
recommended location for an app-bundled tool:

- <https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app>

Distribution behavior is:

- The Homebrew cask exposes the bundled `mactools` binary with its `binary`
  stanza.
- Settings provides “安装命令行工具” and “显示设置命令”. The install action
  creates or replaces only the user-owned `~/.local/bin/mactools` symlink after
  showing the exact target. It never edits shell startup files.
- If `~/.local/bin` is not on `PATH`, Settings shows the appropriate shell line
  for the user to copy. MacTools does not mutate `.zshrc`, `.bashrc`, or other
  shell configuration.
- After installing the broker integration, advanced users may invoke the
  bundled path directly instead of using the symlink.
- No privileged helper and no `/usr/local/bin` write are introduced.

The symlink installer validates an existing path before replacement. It replaces
only a symlink previously owned by MacTools or after explicit confirmation; it
does not overwrite a regular file or another tool.

Release signing must sign the CLI and broker before signing the outer app. The
notarized DMG, Sparkle update, and Homebrew artifact continue distributing one
app bundle.

## Upgrade and Failure Behavior

CLI, broker, and host advertise minimum and maximum supported protocol versions.
They select the highest overlapping version. No overlap returns exit code 10
without forwarding a command.

Ordinarily all three binaries come from one app bundle. The following edge
cases remain defined:

- An old shell symlink resolving into a removed app fails with setup guidance.
- An old CLI pointed at a newer registered broker can proceed only when their
  ranges overlap.
- A running old broker is drained and restarted after app update registration;
  active requests receive their existing reply or a transport failure, never an
  automatic execution retry.
- A newer host may speak an older selected protocol but must omit behavior not
  representable in that version.
- A broker crash loses only routing state. The host reconnects and re-registers;
  the CLI reports uncertain in-flight execution rather than retrying it.
- Unregistering the broker disables new CLI requests. App removal leaves no
  privileged file and launchd eventually removes the invalid bundled service;
  an explicit uninstall action should call `unregister()` first when possible.

## Confirmation and UI Ownership

All confirmation UI is host-owned and uses the same confirmation router as
other canonical action surfaces. For a CLI request, the host may activate only
the confirmation window and return focus afterward when macOS permits. The CLI
prints “Waiting for confirmation in MacTools…” in human mode and remains silent
in JSON mode until the final object.

The exact action reference, source `.cli`, and confirmation text are captured
before presentation. `ActionExecutor` revalidates the provider generation,
execution revision, definition, exposure policy, and availability after the
response. Missing UI, host lock, or inability to order a window fails closed.

## Audit and Recursion

Protocol version 1 may record a bounded, redacted host audit event containing:

- request ID;
- action key without parameters;
- `.cli` source;
- start/finish timestamps;
- outcome category; and
- CLI and host build versions.

Audit storage is off by default until its retention UI is designed. It never
contains parameter values.

The host caps total CLI depth and active CLI requests. Command-running providers
that use a shared host runner should propagate an opaque active-request chain
marker to child processes; a child `mactools` invocation presenting an already
active marker is rejected as recursive. Providers that do not launch through a
shared runner may not be detectable, so canonical action concurrency and global
capacity limits remain the final guard.

## Testing Requirements

Tests use injected identity validators, launchers, clocks, broker transports,
and host bridges. They must not depend on the developer's real LaunchAgent or
modify the user's shell path.

### Protocol and security

- exact and overlapping version negotiation
- unsupported version and unknown-field rejection
- request/response/page/in-flight limits
- wrong user, unsigned client, wrong Team Identifier, and wrong signing ID
- CLI attempting host registration and host attempting CLI methods
- invalid or unavailable identity information fails closed
- sensitive-value redaction in logs, JSON, doctor output, and audit models
- malformed, oversized, duplicate-field, and fuzzed envelopes
- malformed, expired, unknown, over-depth, and active recursive chain markers

### Lifecycle and upgrades

- app missing, invalid signature, and Launch Services mismatch
- broker unregistered, approval required, and broker startup timeout
- host not running, host launch failure, and registry startup delay
- secondary host never registers as authoritative
- broker crash/reconnect and stale host connection removal
- old/new CLI, broker, and host version matrices
- no retry after uncertain `actions.run` delivery
- unregister and moved-app behavior

### Discovery and execution

- catalog action visible but unavailable or CLI-excluded
- unknown action and schema migration failure
- public and sensitive typed parameters from every allowed input form
- sensitive value refused in arguments and insecure/symlink input file rejected
- permission and availability failures
- confirmation approval, denial, timeout, and unavailable UI
- provider generation or availability changing during confirmation
- each concurrency policy
- ordinary completion, durable `started`, provider failure, timeout, and cancel
- interrupt before admission, during confirmation, and during cancellable work
- signal-handler restoration and one cancellation message per interrupted request
- workflow name ambiguity and canonical action execution
- plugin diagnostic snapshots with unloaded or incompatible plugins
- JSON schema snapshots and every exit-code mapping

### Release and distribution

- CLI and broker embedded at expected bundle paths
- inner binaries signed before outer app and strict signature verification passes
- release archive contains the LaunchAgent plist
- Homebrew cask resolves the bundled executable
- symlink installer refuses regular files and foreign symlinks
- debug and release signing identifiers remain distinct

## Rollout

### Phase 0: transport and security spike

Build the protocol module, broker, identity validator, handshake, host launch,
host registration/readiness, and cancellation proof. Validate signed release-
style binaries as well as debug behavior on macOS 14.0 and 14.4+. Do not merge
execution until wrong-team, wrong-user, stale-client, and broker-restart tests
pass.

### Phase 1: read-only discovery

Ship `help`, `version`, `doctor`, action list/describe/availability, workflow
list/describe, and plugin list/describe/doctor with human and JSON output.

### Phase 2: conservative execution

Introduce PluginKit v6, migrate execution sources to a string-backed contract,
add `.cli` source/surface, and rebuild the plugin catalog. Then add parameterless
externally eligible action execution, host-owned confirmation, waiting, durable
acceptance, exit codes, interrupts, and cancellation.

### Phase 3: typed parameters and installation UI

Add public `--parameter`, stdin/restricted-file JSON, sensitive metadata checks,
the `~/.local/bin` installer, release signing changes, and Homebrew exposure.

### Phase 4: richer integrations

Consider progress events, workflow history, Keychain preset references, a public
local SDK, and an MCP adapter only after protocol-1 security and compatibility
data are available.

## Resolved RFC Questions

- **Should MacTools ship a CLI?** Yes, as a local action client.
- **Who owns the listener?** A bundled user LaunchAgent owns the named XPC
  listener; the GUI host owns action state and execution.
- **Does CLI eligibility reuse Run Link policy?** Yes for the broad version-1
  external opt-in, with a separate `.cli` exposure veto.
- **Does the CLI launch MacTools?** Yes by default, without activation, within a
  10-second total startup deadline.
- **Which actions are visible but not runnable?** Published catalog actions may
  be visible with structured eligibility reasons; unpublished actions are
  absent.
- **Are workflow conveniences separate execution operations?** No. Discovery
  may query workflow metadata, but execution resolves and runs the canonical
  workflow action.
- **How are secrets transported?** Standard input or a verified user-only input
  file; never ordinary arguments or URLs.
- **How is the binary installed?** Bundled and signed in the app, exposed by
  Homebrew or a user-owned `~/.local/bin` symlink without privilege.
- **Is this a remote or public API commitment?** No.
