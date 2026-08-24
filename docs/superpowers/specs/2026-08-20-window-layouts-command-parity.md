# Window Layouts Command Parity Specification

Date: 2026-08-20

## Goal

Bring MacTools Window Layouts from the issue #305 focused-window MVP to parity with the selected deterministic window commands in Raycast, then add MacTools custom single-window commands.

The result remains a command-first MacTools plugin. It complements macOS window tiling and does not aim to become a dedicated or continuously running window manager.

## Phase 1

Phase 1 completes focused-window geometry and customization:

- Halves, corners, thirds, fourths, sixths, maximize variants, center, edges, and Reasonable Size
- One gap value with correct outer-edge and shared-seam semantics
- Optional half-screen cycling through half, two-thirds, and one-third sizes
- Stage Manager-aware safe bounds derived from current on-screen geometry
- Persistent custom single-window commands with absolute or relative dimensions, anchors, offsets, duplication, shortcuts, and optional Run Links

## Immediate Parity Follow-up

The parity follow-up ships in the same plugin version:

- Native full-screen toggle
- Previous/next display movement
- A modal shortcut-preset assistant with pending selection, per-command preview and conflict feedback, and an explicit Apply step, plus per-command overrides
- Stable dynamic action IDs and action-catalog revision updates
- Optional brief success feedback for global shortcuts and Trackpad Gestures, with failures always visible

## Safety and Compatibility

- Accessibility permission is required and rechecked at execution time.
- Frames and display topology are refreshed for every operation.
- Writes fail closed when an Accessibility attribute is unavailable.
- Run Links are individually disableable for user-created commands.
- Transient MacTools action surfaces preserve the previously captured target. The ordinary Settings window is eligible only when it is the genuine frontmost window and is captured by exact window number.

## Product Boundary

- Omit previous/next Desktop movement because macOS exposes no public window-to-Space API and the available private boundary is not reliable enough for a user-facing command.
- Keep the scope focused on deterministic commands for one explicitly targeted window. Saved multi-window layouts are out of scope.
- Leave pointer-driven edge snapping, green-button layouts, and interactive tiling previews to macOS.
- Prefer the existing MacTools action surfaces over adding window-manager-specific launchers, overlays, gesture recognizers, or shortcut systems.
- Add future placement commands only when they remain deterministic, reversible, and useful across MacTools action surfaces.

## Non-goals

- Edge-drag snapping, snap-zone overlays, or replacing macOS tiling interactions
- Automatic tiling based on window creation or focus changes
- Per-application or window-title placement rules
- Layout triggers based on display topology, wake, unlock, time, or location
- A visual layout canvas, radial chooser, or green-button palette
- Directional focus, window swapping, incremental grow or shrink, balancing, stash, pin, transparency, close, minimize, hide, or quit commands
- Dedicated layout import/export, cloud sync, or configuration through a CLI
- Captured or automatically restored multi-window layouts
- A general public extension API for third-party plugins to enumerate all windows and Desktops
- Replacing macOS window-server or Stage Manager behavior
