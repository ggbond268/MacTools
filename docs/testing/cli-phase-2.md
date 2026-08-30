# CLI Phase 2 implementation and test checklist

Phase 2 adds narrow action execution to the separately built development CLI. Follow the [Phase 2 contract](../superpowers/specs/2026-08-30-cli-phase-2-execution.md) and the [Phase 0 setup guide](cli-phase-0.md) for signed local installation. This is prototype evidence, not public-release readiness.

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
