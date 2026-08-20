# US-plugins-dock-click-minimize — Hide the active Dock application

Last verified: 2026-08-20

| Field | Value |
| ----- | ------ |
| ID | `US-plugins-dock-click-minimize` |
| Status | `implemented` |
| Domain | `plugins` |
| Actor | macOS user |

## User Story

> As a macOS user, when I plain-click the Dock icon of the already frontmost application, I want the application hidden as with the native Hide command, controlled by a visible switch enabled by default, so that no window is minimized into the Dock.

## Acceptance

- Given the plugin is enabled and Accessibility plus Input Monitoring permissions are granted, when the user plain-clicks the frontmost application's Dock item, then the whole application is hidden after the Dock handles the click.
- Given the clicked Dock item belongs to another application, when it is clicked, then MacTools does nothing and the native Dock activation behavior remains unchanged.
- Given the target application has no visible, non-minimized focused window, when its Dock item is clicked, then MacTools does nothing so macOS can restore or activate it normally.
- Given the click uses Command, Option, Control, or Shift, or targets Trash, a folder, a file, a minimized-window thumbnail, or another special Dock item, then MacTools does nothing.
- Given permissions are unavailable, the plugin is disabled, the event monitor cannot start, or the frontmost application changes before the delayed action, then no application is hidden and the plugin reports the applicable state safely.
- Given the plugin settings page is open, then it shows an enable switch whose value matches the stored preference and uses the existing monitor lifecycle.
- Given no stored preference exists, when the plugin first activates, then the enable switch is on and monitoring starts once permissions are available.

## References

| Type | Source |
| ---- | ------ |
| Feature | `docs/features/dock-click-minimize.md` |
| Code | `Plugins/DockClickMinimize/Sources/DockClickMinimizePlugin.swift` |
| Test | `Plugins/DockClickMinimize/Tests/DockClickMinimizePluginTests.swift` |

## History

| Date | Type | Previous | New | Source |
| ---- | ---- | -------- | --- | ------ |
| 2026-08-20 | created | — | Initial acceptance contract | User brief |
| 2026-08-20 | updated | Click behavior only | Visible enable switch and first-use default enabled | User request |
| 2026-08-20 | updated | Minimize one focused window | Hide the active application without minimizing windows | User request |
