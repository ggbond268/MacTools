# CLI Phase 2: narrow parameterless action execution

## Status

Development prototype for RFC testing. This phase follows merged Phase 1 PR #352 and does not commit the project to public packaging or a stable third-party protocol.

## Command

```text
mactools actions run <id-from-list> [--timeout 1...300] [--json]
```

The default timeout is 60 seconds. Exit codes are 0 success, 2 invalid or no-longer-eligible input, 3 unknown target, 4 currently unavailable or busy, 6 action failure, 7 timeout, 8 cancellation, 9 host/transport failure, and 10 protocol incompatibility. JSON failures remain on stdout; human failures remain on stderr.

## Execution boundary

The CLI submits only the exact opaque ID returned by current discovery and a bounded integer timeout. It never receives or sends PluginKit references, registry objects, parameter values, provider callbacks, or host preferences. The broker remains an authenticated bounded-envelope forwarder and does not load plugins or decide eligibility.

An action is execution-supported only when all of the following hold:

- Its exact reference is catalog-published, registered, portable, and not excluded from the independent CLI exposure surface.
- Its definition is safe and supports background plus automatic execution.
- The reference contains no saved parameter entries and the definition declares zero parameters, including optional parameters.
- For a workflow, every nested workflow and leaf reference meets the same rules; no nested step may contain a saved value.

Discovery can still describe parameterized actions and presets, but reports `executionSupported: false`. A bare key never selects a preset. Guessed, stale, excluded, or parameterized IDs cannot bypass discovery policy.

The host resolves a fresh discovery snapshot, checks current availability, and invokes the existing `ActionExecutor` with `ActionExecutionSource.cli` and background mode. The executor independently revalidates definition/provider revision, catalog publication, parameterlessness, portability, CLI exposure, availability, automatic policy, and concurrency immediately before provider admission. Provider execution remains authoritative.

## Results, privacy, and cancellation

Protocol v3 adds `actions.run`; doctor remains v1-compatible and discovery remains v2-compatible. A successful response contains `{id,status:"succeeded",message?}`. Success messages are stripped of control characters and capped at 1,024 UTF-8 bytes. Provider-authored failure and availability messages never cross the CLI boundary; failures use stable categories.

The requested timeout caps execution even when the provider declares a longer timeout. On timeout or client cancellation, the host task resolves and actively cancels the `ActionExecutionHandle`, including providers that did not advertise interactive cancellation. Ctrl-C requests broker/host cancellation before the client invalidates transport state. Delivery is never retried after an uncertain execution response.

## Compatibility and non-goals

New components negotiate protocol versions 1–3. An older host or broker continues to serve compatible diagnostics/discovery and rejects execution before delivery with exit 10. Request/response shapes, identifiers, timeout bounds, result identity, timestamps, outcomes, and payload/rejection combinations are validated before output.

This phase does not add typed or sensitive parameters, optional-parameter invocation, saved presets, confirmation UI, foreground actions, progress/history, workflow-specific IPC, plugin management, embedding, notarization, Homebrew packaging, or a release. Separate optional CLI distribution remains a later phase.
