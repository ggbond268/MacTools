# CLI Phase 1: read-only action discovery

## Status

Implemented development prototype; signed smoke testing and independent review are required before leaving draft. This is not a public protocol or distribution commitment.

This is a narrow follow-up to merged [Phase 0 PR #340](https://github.com/ggbond268/MacTools/pull/340), following the [maintainer's RFC guidance](https://github.com/ggbond268/MacTools/issues/309#issuecomment-5386412095). The closed [broad prototype #338](https://github.com/ggbond268/MacTools/pull/338) remains reference material, not a branch to merge wholesale.

## Goal

Let users inspect the host's canonical actions from a separately installed CLI without executing actions or duplicating plugin behavior. Keep the Phase 0 authentication, opt-in service lifecycle, cold launch, bounded waits, cancellation, and recovery guarantees.

## Command surface

```text
mactools actions list [--page-size 1...100] [--cursor <opaque-cursor>] [--json]
mactools actions describe <id-from-list> [--json]
mactools actions availability <id-from-list> [--json]
```

Both human-readable and versioned JSON output are supported. The default page size is 50, maximum 100, with a 4,096-entry catalog limit. Oversized catalogs fail explicitly rather than returning partial results.

- `list` returns a deterministically ordered, bounded page of discoverable actions with stable identifiers and concise titles.
- `describe` returns identity, description, relevant capabilities, and sanitized parameter-schema metadata. It must not export parameter values, saved inputs, or sensitive defaults/examples.
- `availability` reports current host-derived availability separately from CLI eligibility. Eligibility describes policy, not permission to execute; Phase 1 has no execution command.
- `help`, `version`, and `doctor` retain their existing behavior. The executable must continue to reject `actions run` and parameter-input flags.

## Ownership and safety

The host owns catalog lookup, readiness, availability, exposure, and eligibility. The broker forwards bounded envelopes and handles authentication/lifecycle only; it must not acquire an action catalog or load plugins. The CLI depends only on the shared protocol package and does not link PluginKit, inspect plugin directories, or read host preferences.

Discovery must not invoke an action, request confirmation, prompt for action permissions, or modify feature configuration. Normal opt-in broker startup may launch the host in the background, as in Phase 0.

## Discovery and eligibility policy

Use a dedicated `.cli` exposure surface, independent of Run Link `externalInvocationPolicy`. Preserve the maintainer's default polarity: `.automatic` means not excluded at the exposure layer, not unconditional execution permission.

The conservative discovery set is catalog-published, currently registered, portable references whose actions are safe, support background operation, include the automatic capability, and are not excluded from CLI exposure. Retain otherwise eligible but currently unavailable actions so users can inspect the reason. Excluded or non-discoverable actions cannot become accessible by guessing an identifier through `describe` or `availability`. The existing string-backed PluginKit surface uses raw value `cli`; no PluginKit ABI or execution-source change is needed.

Current availability and parameter requirements remain separate facts. Parameterized actions expose schema metadata only; Phase 1 accepts no values. Parameterless references use `provider/action`. Parameterized references append `@` and a lowercase SHA-256 digest of sorted-key JSON encoding of the complete canonical reference. This opaque suffix distinguishes presets without exposing their values. A bare key never selects a parameterized preset. Schema changes may change opaque IDs; use current list results.

Descriptions use definition-level title/description, never preset titles/subtitles. Text is capped at 1,024 UTF-8 bytes and stripped of control characters. Up to 32 parameters expose only ID, kind (`string`, `integer`, `double`, `boolean`), requiredness, privacy, and portability; no values/defaults/examples are returned. Every description reports `executionSupported: false`. Availability reports `eligible: true` separately from `available`; the fixed reason `providerUnavailable` replaces arbitrary provider messages that may interpolate private inputs or paths.

Workflows receive no separate command group or IPC interface. Every concrete reference in the dependency graph must satisfy the same discovery policy. Missing, unpublished, disabled, empty, cyclic, invalid, or too-deep dependencies fail closed. Traversal uses the existing eight-level depth limit and a shared 32,768-reference budget; budget exhaustion fails the request rather than yielding partial results.

Keep any PluginKit changes minimal and preserve binary compatibility. A new execution source and executor integration belong to Phase 2, where requests will actually execute actions.

## Protocol and lifecycle requirements

- Keep wire models independent of PluginKit and explicitly validate request/response shapes and semantic combinations.
- Negotiate support before sending new operations. An old Phase 0 peer must yield a bounded, documented incompatibility response for discovery without breaking compatible `version`/`doctor` use.
- Preserve existing JSON envelopes and exit-code meanings; document any additions rather than repurposing old values.
- Specify page-size defaults and limits, opaque cursor validation, deterministic ordering, and behavior when a provider/catalog generation changes between pages. A stale cursor must not silently skip or duplicate results.
- Respect existing message-size and in-flight limits. Test large catalogs and oversized metadata without unbounded host-main-actor work.
- Wait for actual action-registry readiness, not merely an XPC connection or running app. Return a bounded startup error if readiness cannot be reached.
- Preserve timeout cleanup, cancellation, reconnect backoff, and stale-connection callback isolation from Phase 0.
- Do not export sensitive action-reference values through identifiers, metadata, messages, diagnostics, or JSON.

### Wire contract and compatibility

The unchanged handshake negotiates versions 1–2. Doctor remains valid at v1/v2; discovery requires v2. A new CLI rejects discovery before sending it if an old broker/host negotiates v1. Old diagnostics still work with new components. Product versions remain informational. The broker does not interpret discovery catalogs.

Operations are `actions.list`, `actions.describe`, and `actions.availability`. Payloads remain encoded JSON data inside the existing envelope. Unknown fields (including nested/null extras), duplicate fields, malformed identifiers/cursors, invalid page bounds, unknown parameter enums, duplicate parameter IDs, and inconsistent response identity/outcome/timestamp/availability combinations are rejected. Optional inner fields are omitted, not null. Nesting is limited to 64; existing request/response byte and in-flight limits remain unchanged.

Example decoded payloads (the generation below is illustrative):

```json
{"pageSize":50}
```

```json
{"actions":[{"id":"example/status","title":"Status"}],"generation":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
```

```json
{"id":"example/status","title":"Status","description":"Inspect status","parameterSchemaVersion":1,"parameters":[],"executionSupported":false}
```

```json
{"id":"example/status","eligible":true,"available":false,"reason":"providerUnavailable"}
```

Pages sort by full ID. The generation includes host incarnation, eligible sanitized descriptions, provider generations, and execution revisions. A generation mismatch yields `invalidInput/staleCursor`; restart without the cursor. Invalid offsets/syntax yield `invalidInput/invalidRequest`. Availability is read fresh and does not by itself change ordering. Cursors are opaque and cannot survive host restarts.

Both bootstrap completion paths mark registry readiness. Discovery waits at most eight seconds for readiness, checks cancellation, and remains inside the CLI's total ten-second deadline. A ready empty registry succeeds; an unready one returns `hostUnavailable/registryNotReady`. No action permission prompt is requested by discovery.

JSON keeps schema version 1 and the existing envelope fields, with decoded `data`. Exit codes remain 0 success, 2 invalid input, 8 cancellation, 9 host/transport failure, and 10 incompatibility; 3 is added for unknown/non-discoverable targets. Inspecting an unavailable eligible action succeeds with exit 0. JSON failures go to stdout; human failures go to stderr.

## Explicit non-goals

- Action execution, confirmation UI, or foreground-interactive actions.
- Typed/sensitive input transport, saved-preset execution, or parameter-value flags.
- Separate workflow commands, history, progress streaming, plugin management, or MCP.
- Public release packaging, notarization, Homebrew integration, or embedding the CLI in the app.
- A public third-party protocol or network control surface.
- Refactoring unrelated action invocation surfaces or reopening #338.

## Implementation sequence

- Finalize identifiers, pagination, eligibility reasons, compatibility behavior, and JSON fixtures.
- Add independent discovery wire models and codec/semantic tests.
- Implement a host-owned read-only catalog adapter using the existing registry and the dedicated CLI exposure policy.
- Connect the three commands to the authenticated transport and add human/JSON renderers.
- Add client/host lifecycle and regression tests, then run the [Phase 1 test checklist](../../testing/cli-phase-1.md).
- Update `README.md` and an app changelog fragment.
- Keep the PR draft until implementation, required checks, and a fresh code review are complete.

## Compatibility evidence

Phase 0 recorded signed runtime testing on macOS 26 and 27. Its PR still listed macOS 14/15 evidence as outstanding; the merge itself is not proof of that compatibility. Track and obtain that evidence before declaring the optional CLI ready for public release, while testing Phase 1 development on the available macOS 26/27 machines.
