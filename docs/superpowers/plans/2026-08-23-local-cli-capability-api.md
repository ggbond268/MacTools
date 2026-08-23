# Local CLI and Capability API Implementation Plan

**Goal:** Implement the accepted design in
`docs/superpowers/specs/2026-08-23-local-cli-capability-api.md` as four bounded
phases, preserving canonical action ownership and a fail-closed local trust
boundary.

**Architecture:** A signed CLI connects to a user-scoped launchd XPC broker. The
primary GUI host registers a bidirectional host interface after its action
registry is ready. The broker authenticates and routes bounded versioned
envelopes; only the host discovers plugins and invokes `ActionExecutor`.

**Tech Stack:** Swift 6, Foundation XPC, Security, ServiceManagement, AppKit,
SwiftUI, XcodeGen, XCTest, and the existing action/automation/plugin host.

This plan intentionally separates the security spike from user-visible
execution. Phase 0 must be reviewed before Phase 1 or later work is merged.

---

## Phase 0: Transport and Security Spike

### Task 1: Add a transport-neutral protocol module

**Files:**

- Create `Sources/MacToolsCLIProtocol/CLIProtocolVersion.swift`
- Create `Sources/MacToolsCLIProtocol/CLIEnvelope.swift`
- Create `Sources/MacToolsCLIProtocol/CLIProtocolModels.swift`
- Create `Sources/MacToolsCLIProtocol/CLIStrictJSONDecoder.swift`
- Create `Tests/Core/CLI/CLIProtocolTests.swift`
- Modify `project.yml`

Steps:

1. Add a static `MacToolsCLIProtocol` target shared by the CLI, broker, host,
   and tests. Do not place private IPC types in `MacToolsPluginKit`.
2. Define minimum/current protocol versions, request/response headers,
   handshake models, operation names, cancellation, readiness, and redacted
   transport errors.
3. Enforce the 64 KiB request, 4 MiB response, pagination, and request-count
   bounds from the design.
4. Implement strict decoding that rejects unknown and duplicate keys instead of
   relying on `JSONDecoder`'s default unknown-key behavior.
5. Add golden encoding tests, unknown-field tests, boundary-size tests, malformed
   data tests, and version-negotiation matrix tests.
6. Run `make generate`, then the focused `CLIProtocolTests` class.

### Task 2: Implement peer identity validation

**Files:**

- Create `Sources/Core/CLI/CLIPeerIdentity.swift`
- Create `Sources/Core/CLI/CLIPeerIdentityValidator.swift`
- Create `Tests/Core/CLI/CLIPeerIdentityValidatorTests.swift`
- Add a small signed-process integration probe under `Tests/Support/CLI/`
- Modify `project.yml`

Steps:

1. Define an injectable identity-validation protocol returning EUID, Team
   Identifier, signing identifier, signature validity, and designated-
   requirement validity.
2. Resolve a live peer with Security framework APIs while the XPC connection is
   retained; do not validate an arbitrary path supplied by the peer.
3. Require exact role-specific signing IDs and the current process's Team
   Identifier. Reject missing identities and ad-hoc/unsigned peers in production.
4. Add debug fixtures that are explicit build configuration, not environment
   switches accepted by a release binary.
5. Test wrong user, wrong team, wrong signing ID, invalid signature, missing
   metadata, role confusion, and valid host/CLI/broker identities.
6. Run the focused identity tests and the signed-process probe.

### Task 3: Build and register the XPC broker

**Files:**

- Create `Sources/MacToolsCLIBroker/main.swift`
- Create `Sources/MacToolsCLIBroker/CLIBroker.swift`
- Create `Sources/MacToolsCLIBroker/CLIBrokerListener.swift`
- Create `Sources/MacToolsCLIBroker/CLIBrokerConnectionState.swift`
- Create `Configs/MacToolsCLIBroker-LaunchAgent.plist`
- Create `Sources/Core/CLI/CLIBrokerServiceController.swift`
- Create `Tests/Core/CLI/CLIBrokerTests.swift`
- Modify `project.yml`

Steps:

1. Add the broker tool target and copy its LaunchAgent plist into
   `Contents/Library/LaunchAgents`.
2. Advertise one build-configured Mach service. Do not use a user-writable name
   or socket path.
3. Apply a listener code-signing requirement before accepting connections,
   verify EUID, then bind each connection permanently to the host or CLI role.
4. Implement handshake, host registration, request routing, cancellation,
   connection invalidation, per-client/global capacity, and payload limits.
5. Keep no plugin imports, action definitions, filesystem endpoint, payload
   persistence, or parameter logging in the broker.
6. Register/unregister the LaunchAgent through `SMAppService` and expose status
   for doctor/setup UI.
7. Test host replacement, disconnects, late replies, request ID collisions,
   capacity, broker restart, and unauthorized connections.
8. Generate and build the app, then inspect the built bundle for both broker
   executable and LaunchAgent plist.

### Task 4: Register the ready primary host

**Files:**

- Create `Sources/Core/CLI/CLIHostBridge.swift`
- Create `Sources/Core/CLI/CLIHostRequestRouter.swift`
- Modify `Sources/App/MacToolsAppRuntime.swift`
- Modify `Sources/Core/Plugins/PluginHost.swift`
- Create `Tests/Core/CLI/CLIHostBridgeTests.swift`
- Create or update startup coordination tests under `Tests/App/`

Steps:

1. Add an explicit PluginHost readiness snapshot covering built-in/dynamic
   provider synchronization and workflow action publication.
2. Start the broker service controller during primary-host startup, but register
   the exported host interface only after readiness.
3. Never register from the secondary app instance or during tests unless the
   injected transport requests it.
4. Authenticate the broker before exporting the host interface.
5. Route only version-1 discovery/doctor spike operations; return a structured
   unsupported response for execution.
6. Remove registration on termination and reconnect with bounded backoff after
   broker invalidation.
7. Test registry delay, dynamic plugin preparation, secondary-instance behavior,
   termination, and reconnect.

### Task 5: Build the handshake/doctor CLI spike

**Files:**

- Create `Sources/MacToolsCLI/main.swift`
- Create `Sources/MacToolsCLI/CLIApplication.swift`
- Create `Sources/MacToolsCLI/CLIArgumentParser.swift`
- Create `Sources/MacToolsCLI/CLIBrokerClient.swift`
- Create `Sources/MacToolsCLI/CLIHostLocator.swift`
- Create `Sources/MacToolsCLI/CLIOutput.swift`
- Create `Tests/Core/CLI/CLIArgumentParserTests.swift`
- Create `Tests/Core/CLI/CLIHostLocatorTests.swift`
- Create `Tests/Core/CLI/CLIOutputTests.swift`
- Modify `project.yml`

Steps:

1. Add the `mactools` tool target under `Contents/MacOS` without a third-party
   argument-parser dependency.
2. Implement offline `help` and CLI-version output, plus handshake-backed
   `version` and `doctor` human/JSON output.
3. Resolve the containing app through the real executable path first, then
   Launch Services. Verify identity before launch.
4. Launch without activation and retry broker/host readiness within one injected
   10-second deadline.
5. Authenticate the broker and fail closed; never fall back to `CFMessagePort`
   or an unauthenticated transport.
6. Add deterministic argument, JSON, host-location, startup-timeout, approval-
   required, and exit-code tests.
7. Run the CLI-focused test classes and a signed Debug end-to-end handshake.

### Phase 0 review gate

Before proceeding, record results for:

- macOS 14.0-14.3 explicit peer validation;
- macOS 14.4+ XPC peer-requirement defense in depth;
- same user / wrong user;
- same team / wrong team / unsigned;
- host cold launch and registry delay;
- app update with old broker process;
- broker crash and reconnect;
- cancellation round trip; and
- strict signature verification of the built app.

If exact mutual authentication cannot be demonstrated on macOS 14.0, stop and
revisit the deployment target or transport. Do not ship a weaker fallback.

---

## Phase 1: Read-Only Discovery

### Task 6: Add host discovery snapshots

**Files:**

- Create `Sources/Core/CLI/CLIActionDiscoveryService.swift`
- Create `Sources/Core/CLI/CLIWorkflowDiscoveryService.swift`
- Create `Sources/Core/CLI/CLIPluginDiscoveryService.swift`
- Modify `Sources/Core/CLI/CLIHostRequestRouter.swift`
- Create `Tests/Core/CLI/CLIActionDiscoveryServiceTests.swift`
- Create `Tests/Core/CLI/CLIWorkflowDiscoveryServiceTests.swift`
- Create `Tests/Core/CLI/CLIPluginDiscoveryServiceTests.swift`

Steps:

1. Map published `ActionRegistry` entries to redacted protocol DTOs with current
   availability, parameter definitions, execution capabilities, external policy,
   and CLI eligibility.
2. Include excluded/unavailable catalog actions and support the runnable filter.
3. Map workflows by ID and name while retaining their canonical action reference.
4. Map read-only plugin installation, compatibility, trust, load, permission,
   and action-provider diagnostics from PluginHost.
5. Add stable sorting and bounded continuation-token pagination.
6. Verify no DTO contains invocation values, provider closures, local-only data,
   or plugin implementation objects.

### Task 7: Add discovery commands and output

**Files:**

- Modify `Sources/MacToolsCLI/CLIArgumentParser.swift`
- Modify `Sources/MacToolsCLI/CLIApplication.swift`
- Modify `Sources/MacToolsCLI/CLIOutput.swift`
- Create `Tests/Core/CLI/CLIDiscoveryCommandTests.swift`
- Update `docs/actions-automation.md`

Steps:

1. Implement action list/describe/availability, workflow list/describe, and
   plugin list/describe/doctor.
2. Resolve action keys strictly as `provider/action` and workflow identifiers as
   UUID first, then unique exact name.
3. Print concise human output and exactly one stable envelope in JSON mode.
4. Map unknown, unavailable, host, and protocol failures to documented exits.
5. Add JSON golden files and human-output assertions for empty, unavailable,
   ambiguous, incompatible, and paginated results.

---

## Phase 2: Conservative Execution

### Task 8: Add CLI action source and exposure

**Files:**

- Modify `Sources/MacToolsPluginKit/ActionModels.swift`
- Modify `Sources/MacToolsPluginKit/PluginKitCompatibility.swift`
- Modify `Sources/Core/Actions/ActionExecutor.swift`
- Modify `Sources/Core/Plugins/PluginHost.swift`
- Modify exhaustive source switches in host and plugins
- Modify `Plugins/*/plugin.json`
- Modify PluginKit compatibility fixtures, catalogs, and plugin documentation
- Modify `Tests/Core/Actions/ActionModelsTests.swift`
- Modify `Tests/Core/Actions/ActionExecutorTests.swift`
- Modify `Tests/Core/Actions/PluginHostActionRegistryTests.swift`

Steps:

1. Bump PluginKit to v6 and convert `ActionExecutionSource` from an enum to a
   string-backed `RawRepresentable` value while preserving every existing raw
   string. Add `.cli` to it and to `ActionExposureSurface`.
2. Update exhaustive switches, all plugin manifests, compatibility fixtures,
   generated-catalog inputs, and ABI documentation. Rebuild every plugin for the
   new ABI; do not publish a mixed v5/v6 catalog.
3. Apply external invocation policy to both Run Link and CLI sources.
4. Apply `.confirmAlways` to CLI and route `.cli` exposure vetoes through the
   existing repeated pre-execution checks.
5. Add a CLI-specific structured rejection only where existing rejection
   categories cannot express the policy; do not duplicate the executor.
6. Test Codable raw-value compatibility plus allowed, unavailable,
   confirm-always, sensitive, excluded, provider-changed, mode, and availability
   transitions.

### Task 9: Route parameterless execution and results

**Files:**

- Create `Sources/Core/CLI/CLIActionExecutionService.swift`
- Modify `Sources/Core/CLI/CLIHostRequestRouter.swift`
- Modify `Sources/MacToolsCLI/CLIApplication.swift`
- Modify `Sources/MacToolsCLI/CLIOutput.swift`
- Create `Tests/Core/CLI/CLIActionExecutionServiceTests.swift`
- Create `Tests/Core/CLI/CLIActionRunCommandTests.swift`

Steps:

1. Resolve the catalog action, choose background mode when supported, construct
   source `.cli`, and invoke only `ActionExecutor`.
2. Track the request task by request ID and preserve the executor's timeout,
   confirmation, provider revalidation, and concurrency behavior.
3. Use the existing confirmation router and activate only host-owned UI that is
   required for the request.
4. Wait for ordinary completion. Accept `--no-wait` only for durable-progress
   actions and return `started` after admission.
5. Map every executor outcome to one JSON category and documented exit code.
6. Test every risk, concurrency, timeout, cancellation, continuing-action, and
   provider-change path.

### Task 10: Propagate interrupts and bounded recursion markers

**Files:**

- Create `Sources/MacToolsCLI/CLISignalCoordinator.swift`
- Create `Sources/Core/CLI/CLIInvocationContext.swift`
- Modify shared command-running infrastructure where available
- Create `Tests/Core/CLI/CLICancellationTests.swift`
- Create `Tests/Core/CLI/CLIRecursionTests.swift`

Steps:

1. Convert SIGINT/SIGTERM to one cancellation request without doing unsafe work
   directly in the signal handler.
2. Cancel validation/confirmation or a cancellable provider; report exit 8 when
   a final cancellation is known.
3. Preserve durable accepted work after `started` and document uncertain
   transport interruption separately.
4. Propagate an opaque active-request marker through shared host command runners
   and reject a marker already active in the host.
5. Enforce connection/global capacity even when recursion is not detectable.

---

## Phase 3: Typed Parameters and Distribution

### Task 11: Parse and validate typed input

**Files:**

- Create `Sources/MacToolsCLI/CLIParameterInput.swift`
- Modify `Sources/MacToolsCLI/CLIArgumentParser.swift`
- Modify `Sources/Core/CLI/CLIActionExecutionService.swift`
- Create `Tests/Core/CLI/CLIParameterInputTests.swift`
- Extend `Tests/Core/CLI/CLIActionExecutionServiceTests.swift`

Steps:

1. Fetch the current parameter definition before parsing values.
2. Support repeated public `--parameter name=value` values with exact type
   conversion and duplicate detection.
3. Support `--input-json -` and verified regular files opened with no symlink
   following, current-user ownership, user-only permissions, and size bounds.
4. Reject sensitive command-line values before transport and mark the trusted
   input channel in the request.
5. Revalidate schema, privacy, and values in the host, then omit all values from
   outputs and logs.
6. Test shell-visible secret refusal, symlinks, ownership/mode, file replacement,
   malformed JSON, non-finite numbers, duplicate names, bounds, and redaction.

### Task 12: Add command-line-tool setup UI

**Files:**

- Create `Sources/Core/CLI/CLIInstallationController.swift`
- Create `Sources/App/CLISettingsSection.swift`
- Modify `Sources/App/SettingsView.swift`
- Add localized strings to the appropriate `.xcstrings` catalog
- Create `Tests/Core/CLI/CLIInstallationControllerTests.swift`

Steps:

1. Show broker registration/approval state, bundled CLI path, symlink state, and
   setup command in Settings using existing host settings styles.
2. Install only `~/.local/bin/mactools`; never request privilege or edit shell
   startup files.
3. Refuse to overwrite regular files and foreign symlinks. Require explicit
   confirmation when ownership cannot be proven.
4. Add remove/repair actions limited to the MacTools-owned symlink.
5. Keep Chinese copy concise and add tests against a temporary home directory.

### Task 13: Update build, signing, packaging, and Homebrew flow

**Files:**

- Modify `project.yml`
- Modify `.github/workflows/build.yml`
- Modify `.github/workflows/release.yml`
- Modify `scripts/release-local.sh`
- Modify `scripts/install-debug-app.sh`
- Modify `.github/workflows/homebrew-cask-update.yml` or the maintained cask
  template/repository workflow
- Update adjacent script tests

Steps:

1. Build universal CLI/broker binaries and embed the broker plist in the app.
2. Sign CLI and broker before the outer app in local and GitHub release flows.
3. Verify exact signing identifiers, Team Identifier parity, hardened runtime,
   inner/outer strict signatures, notarization, and bundle paths.
4. Ensure debug install preserves/re-registers the broker safely without touching
   a release app's service.
5. Expose the bundled CLI from Homebrew with no copied standalone binary.
6. Add artifact-layout and signing-order script tests.

### Task 14: Documentation, changelog, and release verification

**Files:**

- Modify `README.md`
- Modify `docs/actions-automation.md`
- Create `docs/cli.md`
- Create `docs/testing/cli-e2e.md`
- Create `changes/unreleased/*.md` app changelog fragment
- Extend the existing E2E harness under `scripts/e2e/`

Steps:

1. Document setup, all commands, JSON schema, exit codes, sensitive input,
   confirmation, host startup, and uninstall behavior.
2. Add an E2E pack for cold host launch, signed handshake, discovery, one safe
   parameterless action, cancellation, incompatible protocol, and redaction.
3. Run focused Swift/script tests after each task, then `make build` and the full
   suite because this is cross-module infrastructure.
4. Build a release-style signed app, verify nested signatures, run the CLI from
   the bundle and symlink, and inspect the notarized DMG before release.

---

## Phase 4 Candidates (Separate RFC or Follow-Up Issues)

- versioned progress event stream with backpressure
- paginated workflow history with explicit privacy/retention rules
- Keychain-backed saved parameter references
- public third-party client requirements and compatibility promises
- MCP adapter using the same local capability contract
- dedicated CLI opt-in distinct from Run Link external policy

These are not required to close issue #309's RFC. They should not expand
protocol version 1 without separate review.
