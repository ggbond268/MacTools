# Feature — Vertical Network Rates in Menu Bar

Last verified: 2026-08-20

Status: ready-for-review
Source of truth: yes

## Summary

- Fix issue #275.
- Add an optional vertical upload/download layout for the System Status network menu-bar metric.
- Keep the current horizontal layout as the default.

## User flow

- User enables the Network metric in System Status menu-bar settings.
- User selects Horizontal or Vertical network-rate layout.
- The menu-bar metric updates immediately.
- Vertical layout shows upload on the first line and download on the second line.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| Default layout remains horizontal | This record | `SystemStatusNetworkMenuBarLayout.horizontal` | Configuration storage, menu-bar renderer |
| Vertical layout is opt-in | This record | `SystemStatusNetworkMenuBarLayout.vertical` | Settings picker, menu-bar renderer |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-20 | Keep the existing horizontal layout as default | Issue feedback requests a choice; existing users must not have their menu bar changed | System Status network metric only |
| 2026-08-20 | Render upload above download in vertical mode | Matches the issue reference image | System Status menu-bar renderer only |

## Plan

- [x] P001 — Define the optional layout contract for issue #275.
- [x] P002 — Persist the selected network menu-bar layout.
- [x] P003 — Render vertical upload/download rates and expose a compact settings control.
- [x] P004 — Run focused checks and a separate review.
- [ ] P005 — Commit and open the PR.

## TODO

- [x] F001 — Add persisted layout preference — files: `Plugins/SystemStatus/Sources/SystemStatusConfiguration.swift` — status: done
- [x] F002 — Add vertical network metric rendering — files: `Plugins/SystemStatus/Sources/SystemStatusMenuBarMetricsController.swift` — status: done
- [x] F003 — Add the layout picker — files: `Plugins/SystemStatus/Sources/SystemStatusSettingsView.swift` — status: done
- [x] F004 — Add focused regression coverage — files: `Plugins/SystemStatus/Tests/SystemStatusPluginTests.swift` — status: done
- [x] F005 — Verify and review the isolated change — files: `Plugins/SystemStatus/`, feature record — status: done

## Acceptance / DoD

- [x] Existing users retain horizontal network rates by default.
- [x] Vertical layout is available as an explicit setting.
- [x] Vertical layout renders upload above download with directional arrows.
- [x] The selected layout persists across a settings-controller reload.
- [x] Targeted XCTest and plugin build pass.
- [x] Separate review completed.

## Implementation journal

- 2026-08-20 — Started issue #275 from an isolated GitButler change. Added a persisted `horizontal`/`vertical` display preference, a compact segmented setting, and a dedicated two-line renderer for the network metric. Existing metrics and default network rendering remain unchanged.
- 2026-08-20 — Checks passed: JSON validation for the string catalog, `MacToolsTests/SystemStatusPluginTests` (10 tests), and `make build-plugin PLUGIN=SystemStatus`. The focused XCTest build emitted pre-existing warnings in DiskClean test support and SystemAutomationProviders tests, outside this feature’s files.
- 2026-08-20 — Separate review completed. Checked preference migration fallback, rendering width and line order, menu-bar sampling behavior, settings update propagation, and localized copy. No actionable finding.

## Files

- `Plugins/SystemStatus/Sources/SystemStatusConfiguration.swift`
- `Plugins/SystemStatus/Sources/SystemStatusMenuBarMetricsController.swift`
- `Plugins/SystemStatus/Sources/SystemStatusSettingsView.swift`
- `Plugins/SystemStatus/Tests/SystemStatusPluginTests.swift`
- `changes/unreleased/network-menu-bar-vertical-rates.md`

## Test / QA commands

- `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet -only-testing:MacToolsTests/SystemStatusPluginTests`
- `make build-plugin PLUGIN=SystemStatus`
- Manual: enable the Network metric, switch between Horizontal and Vertical, then relaunch MacTools and confirm the selection persists.
