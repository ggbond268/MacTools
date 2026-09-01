# CLI Phase 1 implementation and test checklist

Discovery is implemented. This guide defines acceptance coverage; the PR tracks current check/review status, not public-release readiness. Follow the [Phase 1 contract](../superpowers/specs/2026-08-26-cli-phase-1-discovery.md) and use the [Phase 0 setup guide](cli-phase-0.md) to build the signed app and separate CLI, enable Command Line, and approve its background item if required.

## Protocol and parsing

- Human and JSON output for all three discovery commands.
- Invalid syntax, unknown identifiers, unsupported commands, and rejection of execution/parameter-input flags.
- Old/new CLI, broker, and host combinations: discovery support is negotiated, compatible diagnostics continue working, unsupported discovery fails clearly and promptly.
- JSON shape, semantic validation, stable exit codes, unknown/duplicate fields, malformed identifiers, invalid page sizes/cursors, and message-size limits.
- Large catalogs, stable ordering, bounded pages, and provider-generation changes between pages.

## Host authority and policy

- Catalog results come only from the host registry, with no plugin loading or host-configuration reads in the CLI/broker.
- Ready, empty, startup-delayed, and failed registry states are distinguishable without hanging.
- Current availability is separate from eligibility; unavailable but discoverable actions retain useful sanitized reasons.
- CLI exclusions apply consistently to list, describe, and availability, including guessed identifiers.
- Safe/background/automatic/portable eligibility is independent of Run Link exposure.
- Missing/reloaded providers and changing availability produce fresh, consistent results.
- Distinct canonical references or presets cannot collide through identifier simplification.
- Workflow dependency checks reject missing, cyclic, or ineligible graphs without introducing workflow-specific IPC.
- Sensitive reference values, defaults, inputs, and examples never appear in output or diagnostics.
- Discovery invokes no action handlers and triggers no action confirmation, permission prompt, or feature-configuration mutation.

## Transport regressions

- Same-user, exact-role, Apple-anchor, and signing-team authentication still fail closed.
- Integration disabled, approval required, app closed, broker unavailable, and interrupted connections retain bounded behavior.
- Terminal startup failure, request timeout, and SIGINT cancellation invalidate XPC state; cleanup stays inside the absolute command deadline.
- Backoff resets only for a current authenticated registration; old callbacks cannot affect a newer connection.

## Required implementation verification

- Run the smallest affected XCTest methods/classes first; record exact commands and results.
- Run `make ci` before pushing cross-module or PluginKit changes. This includes script tests and compatibility validation.
- Run signed local smoke tests on macOS 26 (`mini`) and macOS 27 (`m5.local`), recording commit, OS version, signing identity, installation path, outputs, and exit codes.
- Test hot and cold host startup using a stable separately installed CLI path; verify that the app embeds only its broker.
- Obtain a fresh independent review after implementation and resolve accepted findings before marking ready.

Use an absolute executable path or a separately installed `mactools` on PATH. Copy the complete ID returned by `actions list`, including any opaque suffix; do not assume a built-in ID:

```bash
mactools version --json
mactools doctor --json
mactools actions list --json
mactools actions list --page-size 2 --json
mactools actions describe 'ID-FROM-LIST' --json
mactools actions availability 'ID-FROM-LIST' --json
mactools actions list --cursor 'CURSOR-FROM-PREVIOUS-PAGE' --json
```

Negative checks:

```bash
mactools actions list --page-size 0 --json
mactools actions list --cursor invalid --json
mactools actions describe missing/action --json
mactools actions run missing/action --json
mactools actions list --parameter enabled=true --json
```

Malformed/unsupported commands exit 2; unknown/non-discoverable IDs exit 3. Availability can be false while inspection exits 0. An old Phase 0 component yields discovery exit 10 while diagnostics remain compatible. Unready/disabled integration exits 9 within the deadline; interruption exits 8. Discovery never executes actions.

Focused XCTest classes are `CLIActionDiscoveryTests`, `CLIDiscoveryProtocolTests`, `CLIHostDiscoveryTests`, `CLIArgumentParserTests`, and `CLIExecutableTests`, plus existing transport/security tests. Then run `make ci` for the full suite, script tests, changelog validation, and PluginKit binary compatibility.

## Development evidence (2026-08-27)

The initial local validation passed 51 focused tests, 145 script tests, all 3,062 XCTest tests, changelog validation, and the PluginKit v5 binary-compatibility client. One existing 0.1-second callback expectation and one existing timed preferences-backup test each failed once under load; unchanged-source retries passed. These are recorded as transient verification events, not waived failures. Review subsequently added boundary coverage for eight-level workflows and terminal-page catalog limits; final check counts and review evidence are tracked in the PR.

A later full-suite run exposed an Apple Shortcuts test that assumed `NSCache` would retain an inserted entry. The cache wrapper and controller tests now use controllable storage for deterministic hit, eviction, replacement, removal, and byte-cost checks; production still defaults to memory-pressure-aware `NSCache`. This test-stability fix and the compiler workaround are included in the same Phase 1 PR.

The same Xcode 26.6 / Swift 6.3.3 build was development-signed and tested on:

| Machine | OS/build | Signed smoke checks | Longest successful command |
| --- | --- | --- | --- |
| mini | macOS 26.6.2 / 25G83 | 17 passed | 0.54 seconds |
| m5.local | macOS 27.0 / 26A5421a | 17 passed | 0.50 seconds |

The checks covered help, version, doctor, human/JSON discovery, two-page traversal, descriptions and availability using complete opaque IDs, invalid sizes/cursors, unknown targets, rejected execution/parameter input, cold launch, and stale cursors after restart. Only the Night Shift plugin was installed in the QA data directory; no action was executed. The first macOS 27 doctor call immediately after service registration returned a transient host-transport error; the host stayed alive, a subsequent doctor succeeded, and the complete unchanged-artifact retry passed.

QA artifacts use a separate app/broker/CLI identity and URL scheme, an isolated home through signed artifact `LSEnvironment`, and a separate Finder configuration path. Home/Application Support isolation was independently probed on both OS versions before app launch. Existing Dev app instances were not stopped or overwritten. App, broker, and standalone CLI signatures were verified with the existing development signing team.

Paths on both machines:

- App: `/Users/yihong/Applications/MacTools CLI Phase1 QA.app`
- CLI: `/Users/yihong/Library/Application Support/MacTools CLI Phase1 QA/bin/mactools`
- QA data: `/Users/yihong/Library/Application Support/MacTools CLI Phase1 QA/Home`

These artifacts are for development testing only, not notarized public distribution. Final independent-review and GitHub CI evidence belongs in the PR.

## Public-release compatibility follow-up

- Obtain signed runtime evidence on macOS 14 and macOS 15. Do not mark this complete based on the Phase 0 merge or macOS 26/27 results.
- Resolve the documented installation-path behavior before promising a public installation workflow.

Public release packaging is a later change; this checklist does not authorize signing, notarization, release publication, or changes to remote test machines by itself.
