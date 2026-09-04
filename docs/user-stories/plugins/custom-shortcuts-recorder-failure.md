# US-plugins-custom-shortcuts-recorder-failure — Diagnose recorder startup failures

Last verified: 2026-09-02

| Field | Value |
| ----- | ----- |
| ID | `US-plugins-custom-shortcuts-recorder-failure` |
| Status | `implemented` |
| Domain | `plugins` |
| Actor | macOS user |
| Source | GitHub issue [#346](https://github.com/ggbond268/MacTools/issues/346) |

## User Story

> As a Custom Shortcuts user, when recording an input or shortcut cannot start, I want a clear diagnostic in the mapping card that initiated recording, with the relevant permission action or retry path, so that I can recover without losing my draft.

## Acceptance

- Given `tap.start()` fails for input recording, then the affected mapping card restores the previous draft state and shows a local startup error.
- Given `tap.start()` or `beginShortcutCapture` fails for shortcut recording, then the affected mapping card restores the previous action and enabled state and shows a local startup error.
- Given a missing Accessibility or Input Monitoring permission is confirmed, then the local error offers the corresponding existing permission action and explains where to grant it.
- Given permissions are already granted but the event tap still fails, then the local error offers a retry and does not claim a missing permission.
- Given the user retries, cancels, closes settings, or starts another recorder, then the error and transient recorder state return to a stable idle state.
- Given multiple mappings are visible, then an error is shown only in the mapping card and recording target that failed.
- Given a user changes the input or output mapping or deletes the rule, then any stale recorder error is cleared.
- The capture coordinator remains plugin-local because its arming delay, raw-input capture, emergency stop, and settings cancellation are Input Remapping-specific.

## References

| Type | Source |
| ---- | ------ |
| Feature | `docs/features/input-remapping.md` |
| Code | `Plugins/InputRemapping/Sources/InputRemappingPlugin.swift` |
| Tests | `Plugins/InputRemapping/Tests/InputRemappingModelsTests.swift` |

## History

| Date | Type | Previous | New | Source |
|---|---|---|---|---|
| 2026-09-02 | created | — | Local recorder diagnostics, mapping restoration, permission recovery, retry, and plugin-local coordinator contract | GitHub issue #346 and PR #364 review |
