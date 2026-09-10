# Proposal: an optional stable MacTools CLI v1

Status: draft for maintainer discussion; stable publication is not enabled. See the [signed Nightly acceptance report](../validation/2026-09-10-nightly-signed-acceptance.md) for completed checks and remaining gaps.

Proposal discussion: [#417](https://github.com/ggbond268/MacTools/issues/417).

Related work: [RFC #309](https://github.com/ggbond268/MacTools/issues/309), [managed installation #403](https://github.com/ggbond268/MacTools/issues/403), and [merged implementation #409](https://github.com/ggbond268/MacTools/pull/409).

## Decision requested

Offer the existing, limited CLI to regular MacTools users once signed Nightly acceptance is complete. Keep it optional and separately downloaded. Users who do not install it should receive neither a CLI download nor an automatically enabled integration service.

A small stable command surface is useful for scripts, launchers, diagnostics, and local agents. Stable support should commit to predictable installation, documented machine-readable behavior, and compatible upgrades. It should not depend on implementing the entire RFC first.

## User experience

1. Install the regular MacTools app.
2. Choose **Settings → General → Command Line → Install CLI**.
3. Confirm the matching download, managed paths, included automatic updates, and whether integration should be enabled.
4. Use `mactools` from Terminal, or copy its absolute path if the user's PATH does not include the command directory.
5. MacTools updates an owned CLI with the app. Users can update, remove, or explicitly roll back from Settings.

Required macOS background-item approval remains separate. Disabling integration prevents action access. Removal prevents automatic reinstallation. MacTools does not overwrite manual or Homebrew installations or edit shell startup files.

## Initial supported commands

Promote the existing command surface after auditing its current documentation and compatibility behavior:

- `help`, `version`, and `doctor`.
- `actions list`, `actions describe`, and `actions availability`.
- `actions run <action-id> [--timeout SECONDS] [--json]` for currently eligible parameterless actions.
- Human-readable output and the documented JSON envelope, rejection categories, exit codes, deadlines, and cancellation behavior.

Action execution remains host-owned. Eligibility continues to require safe, background-capable, automatic, portable, CLI-exposed actions without parameters. The host revalidates the action and current availability immediately before dispatch. A stable release does not make every installed plugin action executable through the CLI.

Action IDs come from live discovery. Plugin installation, removal, updates, and provider generation changes can change the catalog; stable CLI syntax does not promise a permanently fixed catalog.

## Distribution and compatibility

- Publish a separately signed and notarized CLI archive for each supported stable app release, with authenticated metadata sealed into the app.
- Retain strict hash, archive, architecture, signing identity, notarization, embedded version/build, ownership, and protocol checks before activation.
- Preserve quarantine and the automatic Gatekeeper assessment followed by full verification when a notarization ticket is not cached.
- Keep stable and Nightly command names, identities, broker services, installation roots, receipts, update feeds, and plugin catalogs isolated. They must coexist without replacing each other's commands or state.
- Begin with Apple silicon, matching the managed installer already implemented. Intel support is a separate decision requiring its own artifact and acceptance coverage.
- Align minimum macOS support with the app's supported release policy. Test the oldest advertised version in addition to macOS 26 and 27 before claiming that support.
- Managed installations follow the app release. Manual installations remain independently managed and may communicate only when supported protocol ranges overlap.
- Document JSON schema, exit-code, and command compatibility. Additive evolution must preserve documented old-client behavior; incompatible changes require an explicit versioned migration.
- Do not silently retry action execution after a timeout, cancellation, or uncertain connection failure. Installation retries and action retries are different operations.

Homebrew publication and embedding the CLI in the app bundle are outside this proposal. A later Homebrew package would need to preserve the officially signed binary and coexist with the managed installer.

## Release gates

Before enabling stable publication:

- [ ] Complete the signed Nightly acceptance matrix for the final candidate on macOS 26 and 27: fresh installation, background approval, disabled/enabled integration, actual quarantined execution, app-driven updates, offline recovery, downgrade, rollback persistence, command collisions, and removal.
- [x] Validate first use in a fresh OS environment before any manual CLI Gatekeeper assessment populates the ticket cache. Passed for the pinned Nightly candidate in clean macOS 26.6.2 and 27.0 RC VMs; see the acceptance report. Repeat for a changed release candidate. A new user account alone does not prove an empty machine-wide cache.
- [ ] Include migration from the legacy disabled automatic-update preference and users who never installed or previously removed the CLI.
- [ ] Validate the stable-specific release artifacts and installation/update path; Nightly success alone does not validate stable packaging.
- [ ] Verify stable/Nightly coexistence with both channels installed and enabled, including manual and Homebrew command collisions.
- [ ] Agree on supported architectures/macOS versions and test that advertised matrix.
- [ ] Review and document the compatibility contract, upgrade failure messages, diagnostics, localization, and recovery instructions.
- [ ] Obtain maintainer approval for the stable distribution policy and release candidate.

Issue #403 should remain open until its signed acceptance criteria pass, or its remaining checks are explicitly transferred to a dedicated release-validation issue before closure. Merging #409 establishes implementation completion, not completion of this matrix.

## Later functionality

After the limited stable CLI is dependable, use focused follow-ups under RFC #309:

1. **Typed parameters for eligible canonical actions.** Describe schemas, validate bounds and types in the host, define bounded JSON input through stdin or an input file, and preserve parameter privacy. Sensitive values must not be placed in ordinary process arguments, logs, or diagnostics. Start with a few concrete user workflows.
2. **Explicit state operations and structured results.** Prefer reading a state and setting a desired value over toggling when scripts need a known result. Extend shared canonical action/result models first so all invocation surfaces agree. Define unavailable, unsupported, and stale observations explicitly; permission to read one state is not permission to export arbitrary plugin-private data.
3. **Convenience integrations where demand exists.** Workflow conveniences, completion, and a local MCP adapter can build on the documented CLI. They should not introduce a second execution engine or broaden authorization.

An example future acceptance scenario is: discover the supported brightness action, read its structured state, request a bounded target value, and confirm the result. This describes a proposed capability, not command syntax available today.

## Suggested implementation sequence

1. Finish and record Nightly signed acceptance without expanding commands.
2. Agree on this stable proposal and its compatibility/platform commitments.
3. Add stable-channel metadata, packaging, managed installation, and isolation tests in a focused PR.
4. Validate a signed stable candidate and publish only after the release gates pass.
5. Scope typed parameters and explicit state/results as separate proposals and PRs, using Nightly for their initial validation.
