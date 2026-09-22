# Documentation

**English** · [简体中文](README.zh-CN.md)

Start with the [English README](../README.md) or [Chinese README](../README.zh-CN.md) for installation and the product overview.

## Feature guides

| Topic | Guide |
| --- | --- |
| Actions, workflows, and automatic rules | [Actions & automation](actions-automation.md) |
| App navigation and external Run Links | [URL API](url-scheme.md) |
| Command-line installation | [Nightly CLI](testing/cli-nightly-distribution.md#install-from-settings) |
| Local AI-agent integration | [CLI agent usage](cli/agent-usage.md) |
| Screenshots, OCR, scrolling capture, and recording | [Screenshot](plugins/screenshot.md) |
| Clipboard backup and restore | [Encrypted clipboard backup](plugins/clipboard-backup.md) |
| Window navigation and arrangement | [Window Switcher](plugins/window-switcher.md) · [Window Layouts](plugins/window-layouts.md) |
| Keyboard, mouse, and gesture mappings | [Input remapping](plugins/input-remapping.md) |
| macOS settings and reusable profiles | [Mac Settings](plugins/mac-settings.md) |
| Menu bar customization | [Hide Menu Bar Icons](plugins/menu-bar-hidden.md) · [Custom icons](plugins/menu-bar-icons.md) |
| Audio controls | [App Volume](plugins/app-volume.md) · [Display Volume](plugins/display-volume.md) |
| Monitoring | [Device Battery](plugins/device-battery.md) · [Duo Status](plugins/duo-status.md) · [AI Usage](plugins/ai-usage.md) |
| Siri | [Usage and limitations](plugins/siri.md) |

## Development

- [Contributing](../CONTRIBUTING.md) / [Chinese](../CONTRIBUTING.zh-CN.md): environment, build, test, and contribution workflow.
- [Plugin development standards](plugins/development-guidelines.md): protocols, widgets, design consistency, performance, and review requirements.
- [Local native plugins](plugins/local-native-plugins.md): develop and debug a plugin.
- [Panel items](plugins/panel-items.md): declare widgets and controls for custom panels.
- [Plugin catalog](plugins/plugin-catalog.md): package discovery and distribution.
- [Presentation and background work](plugins/presentation-performance.md): visibility, observation, and refresh lifetimes.
- [Global panels](plugins/global-panel-presentation.md) and [palette appearance](plugins/palette-appearance.md): focus, dismissal, and shared surfaces.
- [Panel layout validation](testing/panel-layout-editing.md) and [actions/automation verification](testing/actions-automation-e2e.md): focused native checks.

## Releases

- [Build and release workflows](github-actions.md): CI, signing, publication, and channel isolation.
- [Managed CLI installation](plugins/managed-cli-distribution.md) and [CLI release gates](plugins/cli-release.md): ownership, recovery, and signed acceptance.

Detailed design decisions live in [specifications](superpowers/specs/) and [implementation plans](superpowers/plans/). They record design history and are not a substitute for current feature guides.
