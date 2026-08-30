# Feature — Appearance-specific menu bar icons

Last verified: 2026-08-30

Status: implemented
Source of truth: yes

## Summary

- Supports one local menu bar icon for the light appearance and another for the dark appearance.
- Keeps the existing single-icon workflow by using the available local variant for both appearances when only one is configured.
- Reuses the existing appearance observer in the status item controller so the icon changes when macOS switches appearance.

## User flow

- The user opens the Menu Bar Icon settings.
- The user imports a light-appearance icon and a dark-appearance icon independently.
- MacTools displays the matching icon when the menu bar appearance changes.
- The user can still choose an online gallery asset, restore the default icon, or configure only one local variant.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| Light appearance uses the light local selection when available | This file | `MenuBarIconSettings` | Status item controller, settings preview |
| Dark appearance uses the dark local selection when available | This file | `MenuBarIconSettings` | Status item controller, settings preview |
| A missing local variant falls back to the other local variant | This file | `MenuBarIconSettings` | Status item controller, settings preview |
| Online gallery selection remains a single shared selection | This file | `MenuBarIconSettings` | Gallery picker, status item controller |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-30 | Store light and dark local selections as separate persisted values | The issue requires both variants to survive appearance changes and relaunches | Existing local files remain under the current app-support directory |
| 2026-08-30 | Fall back to the configured local variant when the requested appearance has no dedicated icon | Preserves the current one-icon behavior and avoids an unexpected default icon | Importing only one variant remains useful and stable |
| 2026-08-30 | Keep online gallery assets appearance-independent | The issue concerns local custom icons; gallery rendering already adapts through its rendering mode | No gallery catalog or download contract changes |

## Plan

- [x] P001 — Revalidate issue #255 and define the appearance-selection contract.
- [x] P002 — Persist and resolve independent light/dark local selections.
- [x] P003 — Add settings controls, focused tests, and user-facing documentation.
- [ ] P004 — Run the PR gate, review the change, and publish one pull request.

## TODO

- [x] F001 — Add appearance-specific local image and animation imports — files: `Sources/App/MenuBarIconSettings.swift`, `Sources/App/MenuBarIconSettingsView.swift` — status: done
- [x] F002 — Cover fallback, persistence, and appearance resolution — files: `Tests/App/MenuBarIconSettingsTests.swift` — status: done
- [x] F003 — Update user-facing documentation and release notes — files: `README.md`, `changes/unreleased/` — status: done

## Implementation journal

- 2026-08-30 — Issue #255 revalidated as open with no matching pull request or concurrent local branch. The implementation is limited to independent local light/dark selections, fallback behavior, and the existing appearance refresh path.
- 2026-08-30 — `MenuBarIconSettings` now persists independent light/dark local selections, migrates the current single-selection state and older light/dark filenames, and falls back to the other local variant when one is absent.
- 2026-08-30 — `MenuBarIconSettingsView` now exposes one import control and preview per appearance; local image and animation imports target the selected appearance while the online gallery remains shared.
- 2026-08-30 — Focused `MenuBarIconSettingsTests`, `make build`, JSON validation, and `git diff --check` passed. The full `make ci` gate passed its 195 script tests but remains blocked by four unrelated XCTest failures in `DiskCleanPluginTests` and `PluginPackageManifestTests`.
- 2026-08-30 — Manual settings interaction could not be completed in the headless session: the Debug app launched, but no accessibility-visible Settings window was exposed after the deep-link request.
- 2026-08-30 — The status item now observes AppKit effective-appearance changes through a non-interactive child view, so wallpaper and Space transitions can refresh the resolved local icon without relying only on the global theme notification.
- 2026-08-30 — Added legacy filename migration coverage with and without recent-item metadata, dark-only fallback coverage, and same-slot persistence assertions after relaunch. Appearance-specific upload controls now expose localized action labels and stable accessibility identifiers.
- 2026-08-30 — The final `make ci` run again passed all 195 script tests. Four persistent XCTest failures remain outside this change (`DiskCleanPluginTests` and `PluginPackageManifestTests`); one additional `AppleShortcutsCommandRunnerTests` timeout failure passed when replayed in isolation.

## Files

| Area | Files |
|---|---|
| Settings model | `Sources/App/MenuBarIconSettings.swift` |
| Settings UI | `Sources/App/MenuBarIconSettingsView.swift` |
| Host appearance refresh | `Sources/App/MenuBarStatusItemController.swift` |
| Tests | `Tests/App/MenuBarIconSettingsTests.swift` |
| User-facing documentation | `README.md`, `changes/unreleased/menu-bar-icon-appearance.md` |

## Tests / QA

- [x] Verify distinct light/dark local images through the public settings seam.
- [x] Verify persistence, legacy migration, and single-variant fallback.
- [x] Run the focused XCTest class, `make build`, and the repository PR gate.
- [ ] Manually confirm settings import and live appearance switching on macOS when the local UI is available.

## History

<!-- Read only for regression, audit, or an explicit request. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-30 | `pending` | Feature | Appearance-specific local menu bar icon support for issue #255 |
