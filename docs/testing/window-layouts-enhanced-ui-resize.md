# Window Layouts enhanced Accessibility resize validation

## Problem and evidence

Issue [#427](https://github.com/ggbond268/MacTools/issues/427) reports windows moving to a layout's origin while retaining their old size. AX writes can return success without reaching the requested geometry. [Hammerspoon PR #3836](https://github.com/Hammerspoon/hammerspoon/pull/3836) describes enhanced Accessibility animations interfering with consecutive move/resize operations, and temporarily disables `AXEnhancedUserInterface` around its frame transaction.

A controlled local probe on September 13, 2026 reproduced this failure with the flag enabled. All four AX writes returned success, but Right Half produced `(1280, 31, 2560, 1036)` instead of `(1280, 31, 1280, 1036)`, including after a 400 ms wait. Repeating the operation with the flag temporarily disabled produced the requested frame. This establishes a runtime compatibility cause on the tested version; it does not establish why that app originally enabled the flag or prove all failures share this cause.

Environment:

- macOS 27.0, build 26A428, Apple silicon; two displays connected.
- Installed `/Applications/ChatGPT.app`, version 26.908.40834; its bundle identifier on this machine is `com.openai.codex`. This is not evidence for every ChatGPT release or bundle identifier.
- Accessibility permission granted; VoiceOver and Switch Control off.
- `AXEnhancedUserInterface` initially true.
- Logs contained only geometry, AX return codes and boolean state, without window titles or content.

## Implementation boundary

The external-window adapter samples VoiceOver and Switch Control on the main actor. The AX worker revalidates the captured window and, only for resize transactions without either assistive technology active, reads the target application's enhanced-UI flag. Only a supported boolean true is suppressed. False, missing and unsupported values keep the ordinary frame-write path.

Suppression is synchronous on the worker actor and includes the existing frame write, immediate readback and error rollback. It never spans an `await`, the service's settling delays, or a complete pointer gesture. Restoration runs even after cancellation or an ambiguous disable failure, with at most three attempts. An unrecoverable restore failure cannot turn a successful transaction into reported success; when the frame operation already failed, its original error is preserved. The target app can still refuse restoration or disappear, so cleanup is bounded best effort rather than an absolute guarantee.

Move-only operations, host AppKit windows, native fullscreen, existing frame settlement, constrained-size feedback and focus identity checks retain their existing paths. There is no application allowlist and no persisted accessibility setting.

## Validation

The compiled `AccessibilityWindowFrameAdapter` was called by a temporary native diagnostic against the same external window:

| Operation | Requested and observed AX frame | Enhanced UI afterward |
| --- | --- | --- |
| Left Half | `(0, 31, 1280, 1036)` | true |
| Right Half | `(1280, 31, 1280, 1036)` | true |
| Maximize from Right Half | `(0, 31, 2560, 1036)` | true |

Each frame was checked after 400 ms. The diagnostic restored the original frame and verified the flag remained true. This exercises the compiled adapter and worker, not the shortcut dispatcher or an installed replacement plugin.

Focused XCTest coverage includes enabled/disabled/unsupported attributes, assistive-technology bypass, failed disable, cancellation, restoration retries and exhaustion, frame rollback ordering, constrained sizes and negative display coordinates. Existing frame-transaction and in-process AppKit resolver tests also pass (18 tests across those three classes). A further 35 layout-service/session tests and 11 AX cancellation/drag-controller/action-queue tests passed: 64 focused tests total, with no failures or skips.

Remaining native acceptance: macOS 14–26, other ChatGPT versions, real VoiceOver/Switch Control sessions, physical cross-display moves, and minimum-size constrained external apps. Assistive-technology bypass deliberately retains the prior resize behavior, so the original app-specific limitation may remain while those features are enabled. Synthetic tests and a two-display setup do not establish those untested behaviors.
