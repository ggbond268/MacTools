# US-plugins-dock-lock-settings-toggle — Control Dock Lock from Settings

Last verified: 2026-08-20

| Champ | Valeur |
| ----- | ------ |
| ID | `US-plugins-dock-lock-settings-toggle` |
| Status | `ready` |
| Domaine | `plugins` |
| Acteur | `MacTools user` |

## User Story

> As a MacTools user, when I open Dock Lock settings, I want an enable toggle so that I can control Dock Lock without using the menu-bar panel.

## Acceptance

- Given Dock Lock settings are open, then the page shows an enable toggle whose state matches the stored Dock Lock preference.
- When the user enables the toggle with Accessibility permission granted, then Dock Lock starts and the menu-bar panel reports the enabled state.
- When the user disables the toggle, then Dock Lock stops and the disabled state persists for the next launch.
- Given Accessibility permission is missing, when the user enables the toggle, then Dock Lock does not start and the existing permission guidance remains available.

## Références

| Type | Source |
| ---- | ------ |
| Feature | `docs/features/dock-lock.md` |
| Code | `Plugins/DockLock/Sources/DockLockPlugin.swift` |
| Test | `Plugins/DockLock/Tests/DockLockPluginTests.swift` |

## Historique

| Date | Type | Previous | New | Source |
| ---- | ---- | -------- | --- | ------ |
| 2026-08-20 | created | — | Initial settings toggle contract | User request |
