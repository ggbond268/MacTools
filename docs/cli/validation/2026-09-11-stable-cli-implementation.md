# Stable CLI implementation validation — 2026-09-11

Status: implementation prepared for review; stable publication remains disabled. This extends the approved direction in [#417](https://github.com/ggbond268/MacTools/issues/417) and restores the documents reverted after #418. Base: upstream main `7a5f7f56`.

## Scope

Stable installation uses a channel-bound signed manifest, `mactools`, and a separate publisher-scoped store. Nightly paths and owner derivation remain compatible. General settings expose managed stable installation only when the app contains installation metadata; normal stable release packaging omits it while the publication gate is off. Installer confirmation and error text are channel-neutral in all 11 supported languages.

The release workflow builds the selected release tag. Signing, execution verification, and publication use separate jobs; publication depends on successful verification of the same immutable artifact. The committed stable CLI publication flag remains false. Shared behavior is validated through signed Nightly builds, with a locally built, signed and notarized stable candidate required for stable-specific acceptance.

## Automated validation

- 44 focused native installer/controller/service-configuration tests passed, including stable/Nightly simultaneous installation, stable update/rollback/removal without touching Nightly, command collision preservation, channel/identity mismatch rejection, receipt channel tampering, and stable metadata availability.
- Runtime localization tests passed after updating their expectations for channel-neutral wording, including switching languages after a failure has occurred.
- All 260 repository script tests passed. They cover stable manifest binding, shared archive verification with the stable identity, the default-off publication gate, signing/execution job separation, and localized copy. Publication shell fixtures replace GitHub operations locally and verify both enabled/disabled paths and refusal to overwrite an existing CLI release.
- Workflow linting, shell syntax, changelog validation, Markdown links, and personal-identifier scans passed.
- Native panel layout fixtures passed for both left-to-right and right-to-left layouts. PluginKit v6 binary compatibility passed.

## Full-suite baseline limitation

`make ci` was run. The initial native run passed 4,638 of 4,642 tests. Two failures were outdated localization expectations introduced by changing the wording; those expectations were corrected and the localization class passed on rerun. An unrelated keyboard modifier test passed on isolated rerun.

One source-scanning test still fails on unchanged upstream code: `PluginPresentationSafetyTests.testEveryWindowPresentationCallsiteUsesTheSharedSafetyBoundary`. The screenshot plugin's folder chooser calls `PluginPresentationSafety.prepareForWindowOrdering`, but more than 240 characters before `panel.runModal()`, outside the scanner's look-back window. Both the plugin and test match base `7a5f7f56`; neither is modified by this PR. This blocks claiming a completely green full suite. The UI fixture and binary compatibility checks that follow XCTest in `make ci` were run separately and passed.

## Signed acceptance still required

No stable signing, notarization, release workflow dispatch, release publication, new VM creation, or physical app replacement was performed for this implementation. Unsigned automated tests do not establish signed stable acceptance. The [earlier signed Nightly report](2026-09-10-nightly-signed-acceptance.md) remains historical evidence for its pinned candidate, not for these new stable artifacts.

Before enabling publication, complete the remaining Nightly matrix and stable-specific signed installation/update/recovery/coexistence checks, including the app's oldest supported macOS version. See the [release procedure](../../plugins/cli-release.md). This PR does not close #403 or claim completion of #417's release requirements.

The dedicated candidate-only CI mode was removed after review exposed its dependence on release-tag checkout. Release runs remain tag-based; local candidate validation does not require creating a release tag or changing the publication gate. After this workflow/documentation change, all 57 focused manifest, archive, and release-policy script tests passed, along with workflow linting, shell syntax, and documentation checks. Native code was unchanged, so the native suites were not rerun.
