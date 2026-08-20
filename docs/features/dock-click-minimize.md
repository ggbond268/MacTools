# Feature — Dock Click Hide

Last verified: 2026-08-20

Status: implemented
Source of truth: yes

## Summary

- Add the `dock-click-minimize` productivity plugin.
- A plain click on the Dock item for the already frontmost application hides the application.
- All other Dock interactions keep native macOS behavior.

## User flow

- User enables the plugin in its primary panel.
- MacTools requests or displays normal Accessibility and Input Monitoring permission guidance.
- A listen-only event tap observes a plain left mouse down.
- Accessibility hit testing resolves the clicked Dock item by bundle identifier.
- MacTools waits briefly for macOS to handle the click, revalidates the target, and hides the application.

## Business rules

| Rule | Markdown | Central code | Consumption |
| ---- | -------- | ------------ | ----------- |
| This feature has no durable business rule outside its technical interaction contract. | This document and `docs/user-stories/plugins/dock-click-minimize.md` | — | — |

## Decisions

| Date | Decision | Reason | Impact |
| ---- | -------- | ------ | ------ |
| 2026-08-20 | Observe clicks with a listen-only CGEvent tap. | Preserve native Dock event delivery. | The plugin performs a delayed, validated native Hide action only. |
| 2026-08-20 | Resolve applications by AX URL and bundle identifier. | Avoid localized app-title matching. | Dock folders, files, Trash, and unknown items fail open. |
| 2026-08-20 | Hide the active application with `NSRunningApplication.hide()`. | Match the native Dock contextual Hide command. | No windows are minimized into the Dock. |
| 2026-08-20 | Show an enable switch in the settings page and default it to enabled on first use. | Make the feature immediately usable and controllable from the shown UI. | Existing persisted preferences remain unchanged. |

## Plan

- [x] P001 — Define the user-story and feature acceptance contracts.
- [x] P002 — Create the manifest, bundle entry point, localization, and testable decision model.
- [x] P003 — Implement the Dock Accessibility resolver, application hider, and listen-only event monitor.
- [x] P004 — Integrate lifecycle and permission handling in the plugin primary panel.
- [x] P005 — Add focused tests and user-facing documentation.
- [x] P006 — Generate, build, test, review, and record the checks.
- [x] P007 — Add the settings switch and first-use enabled default.
- [x] P008 — Replace window minimization with application hiding.
- [x] P009 — Complete UI localizations and align user-story headings with repository language rules.
- [x] P010 — Centralize plugin log categories.

## TODO

- [x] F001 — Define acceptance contract — files: `docs/user-stories/plugins/dock-click-minimize.md`, `docs/features/dock-click-minimize.md` — status: done
- [x] F002 — Create plugin surface and pure decision logic — files: `Plugins/DockClickMinimize/` — status: done
- [x] F003 — Implement macOS system boundaries — files: `Plugins/DockClickMinimize/Sources/` — status: done
- [x] F004 — Add lifecycle and permission tests — files: `Plugins/DockClickMinimize/Tests/DockClickMinimizePluginTests.swift` — status: done
- [x] F005 — Document the released plugin — files: `README.md`, `changes/unreleased/` — status: done
- [x] F006 — Verify generated targets and builds — files: `docs/features/dock-click-minimize.md` — status: done
- [x] F007 — Expose persisted enable state in settings and update first-use default — files: `Plugins/DockClickMinimize/` — status: done
- [x] F008 — Hide the active application rather than minimize a window — files: `Plugins/DockClickMinimize/` — status: done
- [x] F009 — Complete localized UI strings and normalize user-story headings — files: `Plugins/DockClickMinimize/Resources/Localizable.xcstrings`, `docs/user-stories/plugins/dock-click-minimize.md` — status: done
- [x] F010 — Centralize the Dock Click Hide log categories — files: `Plugins/DockClickMinimize/Sources/DockClickLog.swift` — status: done

## Implementation journal

- 2026-08-20 — P001/F001 complete. Created the executable user-story and feature contracts from the supplied behavior specification. Business-rule documentation is intentionally not needed because the rules are limited to this plugin's interaction contract.
- 2026-08-20 — P002–P005/F002–F005 complete. Added the standalone plugin, a bounded listen-only event tap, AX URL/bundle-based Dock target resolution, focused-window minimization, permission lifecycle, deterministic mocks, English README entry, and unreleased plugin changelog. Swift parsing and JSON validation pass. `make generate` passes. `make build-plugin PLUGIN=DockClickMinimize` is blocked while compiling existing `MacToolsPluginKit`: `ActionReference` is referenced but absent from the generated target.
- 2026-08-20 — P006/F006 partial. Separate review found no issue in the plugin diff. Scope is clean for this feature; unrelated uncommitted Dock Lock work remains outside it. `git diff --check`, Swift parsing, manifest JSON, and string-catalog JSON pass. Targeted XCTest and plugin build remain blocked by the pre-existing missing `ActionReference` type in `MacToolsPluginKit`; manual macOS acceptance remains required.
- 2026-08-20 — P006/F006 complete. `DockClickResolver.swift:92` now advances the mutable AX parent cursor without shadowing it and converts verified AX elements with `unsafeDowncast`. `make build`, `make run`, and `xcodebuild -only-testing:MacToolsTests/DockClickMinimizePluginTests` pass. DiskClean tests still emit unrelated Swift concurrency warnings; manual macOS Dock acceptance remains required.
- 2026-08-20 — Manifest compatibility fix. The new plugin initially declared PluginKit v4 while the current plugin catalog is v5-only. Aligned `pluginKitVersion` to `5` and `minHostVersion` to `1.2.0`, matching every current plugin and the catalog preflight requirement.
- 2026-08-20 — P007/F007 started. The screenshot confirms that the plugin settings page currently exposes permission cards only. Add the requested form toggle and default it to enabled only when no saved preference exists.
- 2026-08-20 — P007/F007 complete. `settings: form` now exposes the persisted switch in the settings page; first launch defaults to enabled while saved preferences override it. Swift parsing, JSON validation, `make build-plugin PLUGIN=DockClickMinimize`, and `MacToolsTests/DockClickMinimizePluginTests` pass. The global user-story validator still reports the unrelated legacy Dock Icon story structure.
- 2026-08-20 — P008/F008 started. Replace the visible behavior with macOS Hide: retain Dock target resolution, permission gating, event observation, delayed frontmost-app revalidation, and all-minimized restore protection; remove all window-minimization calls.
- 2026-08-20 — P008/F008 complete. `DockApplicationHider.swift` now validates a visible focused or main window, then uses `NSRunningApplication.hide()` for the resolved target process. The plugin keeps the delayed frontmost-app revalidation and no-op restore guard. Localized user copy now says Hide. Swift parsing, JSON validation, `make build-plugin PLUGIN=DockClickMinimize`, and `MacToolsTests/DockClickMinimizePluginTests` pass.
- 2026-08-20 — P008 review complete. Reviewed the application identity, visibility guard, delayed-action race checks, and user-facing copy; no new issue found. `make run` rebuilt and installed the Debug app with the refreshed local plugin catalog.
- 2026-08-20 — P009/F009 complete. Replaced French user-story structural headings with English to match repository documentation rules. Completed all Dock Click Hide UI string translations for every locale already declared by the plugin manifest.
- 2026-08-20 — P010/F010 complete. Centralized Dock Click Hide OSLog categories in the plugin-private `DockClickLog`; dynamic plugins cannot depend on the host App target’s `AppLog`.

## Current files

| Area | Files |
| ---- | ----- |
| UI | `Plugins/DockClickMinimize/Sources/DockClickMinimizePlugin.swift` |
| System interaction | `Plugins/DockClickMinimize/Sources/DockClickMonitor.swift`, `DockClickResolver.swift`, `DockApplicationHider.swift` |
| Tests | `Plugins/DockClickMinimize/Tests/DockClickMinimizePluginTests.swift` |
| Documentation | `docs/user-stories/plugins/dock-click-minimize.md`, `README.md`, `changes/unreleased/dock-click-minimize.md` |

## Files to create or modify

- `Plugins/DockClickMinimize/`
- `README.md`
- `changes/unreleased/`

## Tests / QA

- [x] Plugin lifecycle and missing-permission behavior — deterministic XCTest added; execution blocked by shared build failure.
- [x] Pure Dock-click decision cases — deterministic XCTest added; execution blocked by shared build failure.
- [x] Visible-window guards — deterministic XCTest added and passing.
- [x] Delayed-action race guards — deterministic XCTest added; execution blocked by shared build failure.
- [x] Generated plugin build and focused XCTest.
- [x] Settings switch, persistence, and first-use enabled default.
- [x] Application hiding, visible-window guard, and delayed-action race guards.
- [ ] Manual macOS Dock acceptance checks.

## History

| Date | Commit | Type | Notes |
| ---- | ------ | ---- | ----- |
| 2026-08-20 | uncommitted | Feature | F001 done — interaction contract recorded. |
| 2026-08-20 | uncommitted | Feature | F002–F005 done; F006 partial — shared build blocker recorded. |
| 2026-08-20 | uncommitted | Feature | F007 done — visible settings switch and first-use default enabled. |
| 2026-08-20 | uncommitted | Changed | F008 done — active Dock application is hidden without minimizing windows. |
