# Feature — zsh Config Editor Stability

Last verified: 2026-08-20

Status: in-review
Source of truth: yes

## Summary

- Fix issue #110.
- Keep caret, focus, and viewport stable while editing zsh configuration files.
- Defer full-document syntax highlighting until typing pauses.

## User flow

- User edits a long zsh configuration file in the inline editor.
- Text and unsaved-change state update immediately.
- Syntax highlighting refreshes shortly after typing stops.
- Selection and viewport stay unchanged by the highlighting pass.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| No durable business rule | — | — | — |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-20 | Use a 100 ms coalesced delay for full-document highlighting | Avoid synchronous layout invalidation on every keystroke without removing highlighting | Editor only |
| 2026-08-20 | Keep highlighting on the main queue | NSTextView and NSTextStorage are AppKit UI state | Editor only |

## Plan

- [x] P001 — Define the focused correction and acceptance contract.
- [x] P002 — Add coordinator-level regression tests for delayed, coalesced, and cancelled highlighting.
- [x] P003 — Defer highlighting and preserve editor selection and viewport.
- [x] P004 — Run targeted checks and a separate review.
- [x] P005 — Commit and open the PR for issue #110.

## TODO

- [x] F001 — Add delayed highlighting coordinator behavior — files: `Plugins/ZshConfig/Sources/ZshSyntaxHighlightingEditor.swift` — status: done
- [x] F002 — Add editor regression tests — files: `Plugins/ZshConfig/Tests/ZshSyntaxHighlightingEditorTests.swift` — status: done
- [x] F003 — Add release note — files: `changes/unreleased/zsh-config-editor-stability.md` — status: done
- [x] F004 — Verify the focused diff — files: `Plugins/ZshConfig/`, `docs/features/zsh-config-editor-stability.md` — status: done
- [x] F005 — Complete the separate review — files: `Plugins/ZshConfig/`, `docs/features/zsh-config-editor-stability.md` — status: done

## Acceptance / DoD

- [x] Text binding updates immediately after an edit.
- [x] Rapid edits result in one delayed highlighting pass.
- [x] Replaced content cancels a pending highlighting pass.
- [x] Highlighting preserves the current selection and viewport.
- [x] Targeted XCTest and plugin build pass.
- [ ] Manual QA confirms no focus or viewport jump in a long `.zshrc`.
- [x] Separate review completed.

## Implementation journal

- 2026-08-20 — Added a 100 ms main-queue debounce in the NSTextView coordinator. Pending work is cancelled for external replacements and view teardown. Highlighting now restores the selection and scroll origin without taking first responder status. Added focused coordinator tests and a plugin release-note fragment. No manifest, registry, or inventory change is required because this changes existing plugin source and tests only.
- 2026-08-20 — Checks passed: Swift parse for ZshConfig source and tests; `MacToolsTests/ZshSyntaxHighlightingEditorTests` (5 tests); and `make build-plugin PLUGIN=ZshConfig`. The targeted MacTools test build emitted existing Swift 6 warnings in DiskClean test support, outside this feature's diff.
- 2026-08-20 — Separate review completed. Checked coordinator lifecycle, main-actor isolation, cancelled work, selection/viewport restoration, undo protection, and tests. No actionable finding. UI automation opened the editor but could not click the offscreen accessibility element; the AppKit viewport test covers that invariant, while a human long-file typing pass remains recommended.
- 2026-08-20 — Commit `682d29c9` created and PR #319 opened. Scope check against `upstream/main` confirms one commit and only the five ZshConfig/documentation/changelog files.

## Files

- `Plugins/ZshConfig/Sources/ZshSyntaxHighlightingEditor.swift`
- `Plugins/ZshConfig/Tests/ZshSyntaxHighlightingEditorTests.swift`
- `changes/unreleased/zsh-config-editor-stability.md`
- `docs/features/zsh-config-editor-stability.md`

## Test / QA commands

- `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet -only-testing:MacToolsTests/ZshSyntaxHighlightingEditorTests`
- `make build-plugin PLUGIN=ZshConfig`
- Manual: edit a long `.zshrc`, rapidly type in the middle and near the end, use undo/redo, change file, and resize the settings window.

## History

<!-- Read only for bugs, regressions, audits, or explicit requests. -->

| Date | Commit | Type | Notes |
| 2026-08-20 | `682d29c9` | Fix | Deferred and coalesced zsh editor highlighting for #110 |
