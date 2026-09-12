# Signed Nightly CLI acceptance progress — 2026-09-10

Status: partial acceptance. Do not close [#403](https://github.com/ggbond268/MacTools/issues/403) as fully validated or enable stable CLI publication from this report alone.

Signed first installation, uncached-ticket recovery, and background-permission denial, guidance, and recovery passed in clean macOS 26.6.2 and 27.0 RC VMs. Both systems automatically enabled the first background registration; neither presented an initial pending-approval prompt.

The [stable CLI v1 proposal](../proposals/stable-cli-v1.md) is tracked in [#417](https://github.com/ggbond268/MacTools/issues/417) while the remaining signed checks are completed. Environment labels below describe OS versions and test conditions rather than personal devices.

## Candidates and scope

The primary candidate came from a separate signed Nightly distribution:

- App and CLI: `1.3.1 (1789056230.1)`.
- Source snapshot: `0381daeeb21017e81f0515b7903d3885d2312735`.
- Reviewed checkout: `bde41c83`, the final PR #409 documentation commit. All six files in `Sources/Core/CLI/Installation/` and `Sources/App/CLIInstallSettingsView.swift` are byte-identical to this candidate's source snapshot.
- CLI architecture: arm64, as declared in the sealed manifest.
- App DMG SHA-256: `b1b85ff4cbb6116d8488aec1f8a679b3a46d5396d35d82819ac3ad73aefc80cd`.
- CLI ZIP SHA-256: `6482f1040ffb08f3b4aa295f275c62dfe17814d89b64af183efcdcd1a0ad78a9`.

The downloaded DMG and CLI ZIP matched the published artifacts. CLI hash and size matched `cli-install.json` sealed inside the signed app. Publisher records reported both artifacts accepted by the notary service. The app passed strict signature verification and Gatekeeper assessment inside the read-only mounted DMG.

Physical macOS 26 UI tests used the separate upstream `nightly-23-1` candidate: app and CLI `1.3.0 (23.1)`, source `2d55ee73961ae1427de8ebfad13407b8eb96a439`. Its six installer files and settings view also match the reviewed implementation. Its published DMG checksum, app signature, Gatekeeper assessment, publisher identity relative to the existing upstream app, and sealed manifest/build binding passed.

These candidates are distinct artifacts. The primary candidate includes other integration changes. Results apply to the identified installer source and tested packages; they do not establish stable-channel packaging acceptance.

## Physical-environment results

The physical macOS 27 environment had an existing installation, prior background approval, and cached notarization tickets. The physical macOS 26 UI environment had no managed CLI when testing began, but already had an upstream background-item grant. A separate existing macOS 26 installation received read-only version and broker checks only.

| Check | Physical macOS 27; primary candidate | Physical macOS 26; upstream 23.1 unless noted |
| --- | --- | --- |
| Signed installed app/CLI verification | Passed | Passed |
| Quarantined CLI `version --json` | Passed | Passed |
| Enabled integration: `doctor --json` and matching app/broker build | Passed | Passed |
| Read-only action discovery | Passed; six action summaries | Passed |
| App-driven CLI upgrade | Passed: verified app replacement and launch upgraded CLI `1788990658.1` to `1789056230.1` | User-reported prior pass; exact builds not recorded |
| Prior version retained after upgrade | Passed | Not observed |
| Integration disabled/enabled through Settings | Passed: disabled version exits 0, doctor exits 9 with `hostUnavailable`; re-enabling restores doctor | Passed: disabled version exits 0, doctor and discovery exit 9; re-enabling restores doctor |
| Explicit rollback | Passed through Restore Previous Version to `1788990658.1` | User-reported prior pass; exact builds not recorded |
| Rollback across restart of the same app release | Passed; rollback hold retained | Pending |
| Explicit Update after rollback | Passed | Pending |
| Removal through Settings | Passed | Passed |
| No automatic reinstall after removal and app restart | Passed | Passed |
| Unmanaged regular-file collision | Passed; fixture bytes and inode preserved | Passed; fixture bytes and inode preserved |
| Retry after removing the test collision | Passed | Passed |
| Installation confirmation | Observed version, size, paths, integration choice, automatic updates, and possible macOS approval | Passed with matching build and details |
| First use with an uncached notarization ticket | Covered separately in the clean VM | Passed: static requirement failed before installation and passed afterward on the unchanged probe |
| Offline update/recovery | Passed with process-only network denial; old CLI preserved and normal-network restart recovered | Fresh-install failure and subsequent online installation passed; existing-CLI offline update pending |
| Legacy disabled update-preference migration | Passed using a backed-up signed legacy installation with `automaticUpdates=false` | Pending |
| CLI absent before explicit first installation | Covered separately in the clean VM | Passed |
| App downgrade and next-release update after rollback hold | Pending | Pending |
| Other collisions, channel/publisher isolation, and download/activation faults | Automated PR coverage exists; signed runtime matrix incomplete | Automated PR coverage exists; signed runtime matrix incomplete |

The observed app-driven upgrade used manual replacement from a verified DMG followed by normal app launch. It does not validate a complete Sparkle download/relaunch update. User-reported upgrade and rollback results do not establish the unrecorded restart, next-release, or migration variants.

The macOS 27 offline/migration fixture used the real signed legacy executable and receipt, with its update preference set to false and the current store backed up separately. Denying outbound networking only to the signed app caused an update failure while retaining the old executable, command link, and receipt without pending activation. Normal-network relaunch updated the CLI, retained the previous version, and restored successful doctor output. This tests controlled network denial, not the exact error wording of disconnected Wi-Fi or Ethernet.

Physical macOS 26 UI automation used a temporary helper after the user granted Accessibility permission. That permission is separate from MacTools background approval. The uncached CLI probe was neither executed nor manually Gatekeeper-assessed before installation; its unchanged static notarization result changed from exit 3 to exit 0 after the app installed the CLI. Quarantine remained present. A later network-denied fresh installation failed without activation; a confirmed online retry succeeded with integration disabled.

A temporary installer-lock experiment expired before the attempted update and is not counted as a successful busy/error-recovery test.

## Clean VM validation

Two clean OS baselines were installed from Apple restore images using Tart 2.37.0. The downloaded Tart archive matched SHA-256 `d531752c4dad5d4214ac7ff540cefc2647df1fca2338d413d3c01754f54b356b`, and passed strict signature verification and Gatekeeper assessment. Separate APFS clones were used for testing:

- macOS 26.6.2 (`25G83`).
- macOS 27.0 RC (`26A428`).

Both guests used disposable local accounts without an Apple Account. Each baseline had no MacTools app or CLI. Tests used the same primary candidate identified above.

On each OS, Safari downloaded the pinned DMG. Quarantine and the checksum were verified, strict app signature and Gatekeeper checks passed, and the normal first-launch confirmation was accepted. Launching the app did not install a CLI automatically.

Before in-app installation, a non-executed CLI probe downloaded from the sealed manifest matched the archive checksum and failed the static notarization requirement with exit 3. No manual CLI Gatekeeper assessment was performed. Installation through the actual app confirmation succeeded, and the unchanged probe then passed with exit 0. The installed CLI retained quarantine. Version and doctor reported matching app/CLI/broker build `1789056230.1` and protocol 3. Discovery completed with an empty list because no plugins were installed.

Both OS versions automatically enabled initial background registration. Disabling the MacTools entry through native System Settings caused doctor to return `hostUnavailable`, exit 9, and background-item guidance. MacTools displayed pending-approval text and the **Allow in Background** button. Clicking that button opened the correct Settings page. Re-enabling the item and returning to MacTools restored doctor exit 0 without reinstalling.

| Clean VM check | macOS 26.6.2 | macOS 27.0 RC |
| --- | --- | --- |
| CLI absent before explicit installation | Passed | Passed |
| Signed app installation with Safari quarantine | Passed | Passed |
| First CLI install with demonstrated uncached ticket | Passed | Passed |
| Initial background registration | Automatically enabled | Automatically enabled |
| Disabled background permission blocks app access | Passed; doctor exit 9 | Passed; doctor exit 9 |
| Pending-approval guidance and Settings button | Passed after disabling permission | Passed after disabling permission |
| Permission restoration without reinstalling | Passed; doctor exit 0 | Passed; doctor exit 0 |

These tests exercised real native UI and macOS service state. No mock service, TCC database edits, product re-signing, or quarantine removal were used. No separate human permission prompt occurred during the guest background toggles. The observed denial/recovery behavior does not establish a first-registration pending-approval prompt that macOS did not show.

## Final state and evidence retention

The physical macOS 27 installation finished on the matching primary app/CLI candidate with integration enabled, automatic updates enabled, the prior CLI retained, and no pending activation or rollback hold. The separate read-only macOS 26 installation was unchanged. Physical macOS 26 UI testing ended with the test CLI removed, the temporary upstream broker unregistered, and the test app quit; the existing installed app was preserved.

Physical-test recovery backups and evidence were retained separately. Personal device names, account names, private paths, distribution addresses, and signing identities are omitted from this report.

VM logs and screenshots were reviewed to produce the result summary above. Both guests were shut down cleanly, and all four baseline/test VMs were verified stopped. After validation, all four VMs and their isolated tooling, runtime, launch shortcuts, disposable credentials, logs, screenshots, and release metadata were deleted at the user's request. Cleanup recovered approximately 60 GiB of available storage. The durable VM evidence is this sanitized result summary; the raw VM evidence and resettable baselines are no longer retained. Existing app installations, release-publishing infrastructure, unrelated simulators, and physical-test recovery backups were preserved.

## Remaining work before closure

1. Track the unobserved OS-generated first-registration pending-approval case separately from the completed disabled-permission guidance and recovery checks.
2. Complete the outstanding signed runtime scenarios: macOS 26 existing-CLI offline update and legacy preference migration; rollback persistence where unobserved; app downgrade and next-release rollback-hold behavior; and the remaining collision, isolation, and download/activation fault cases.
3. Validate the full Sparkle download/relaunch path if it is used for the release candidate.
4. Validate the oldest advertised macOS version, supported architectures, and stable-specific artifacts and coexistence before stable publication.
5. Close #403 only after its acceptance criteria pass, or explicitly transfer remaining checks to a dedicated release-validation issue before closing it as implementation-complete.

No product source, GitHub issue state, or publication settings were changed during VM validation. The stable proposal can be discussed while these release gates remain open.
