# Window Layout Plugin Design

Date: 2026-08-10  
Status: approved  
Scope: MacTools plugin only; mobile companion deferred indefinitely for this roadmap

## Context

MacTools is a single menu-bar host that integrates many utilities as installable plugins. The product roadmap for Better365-like capabilities (integrated into one app, not separate apps) is:

1. Window layout (this spec) — new plugin
2. Battery charge-protection enhancements — extend `BatteryChargeLimit`
3. Menu-bar icon management enhancements — extend `MenuBarHidden`
4. System status enhancements (Mac only) — extend `SystemStatus`

Mobile/app linkage (e.g. State-style phone monitoring) is explicitly out of scope for now.

## Goal

Add a first-class **Window Layout** plugin that lets users resize and position the frontmost resizable window using Pane-like presets, via the feature panel and optional global shortcuts, within one MacTools install.

## Non-goals (phase 1)

- Edge-drag snap while moving a window (phase 2)
- One-click two-window left/right split (phase 2)
- Custom grid editors, saved layouts beyond restore-last
- Separate standalone App Store binary for layout only
- Any mobile companion

## Approach

**Independent plugin** `Plugins/WindowLayout/` (plugin id `window-layout`).

Do not fold into `WindowSwitcher` (different job). Do not move geometry into Core until a second consumer exists.

## Architecture

```
Feature panel / global shortcuts
        │
        ▼
WindowLayoutPlugin
        │
        ├─ WindowLayoutGeometry     pure rect math from visible frame V
        ├─ WindowLayoutApplicator   Accessibility: resolve target window, get/set frame
        ├─ WindowLayoutHistory      per-window pre-layout snapshot for restore
        └─ WindowLayoutStore        preferences (e.g. almost-maximize inset)
```

Host concerns only: plugin load order, settings chrome, shortcut recording UI, accessibility permission card rendering.

### Module responsibilities

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `WindowLayoutPlugin` | Panel state, settings page, shortcut handlers, permission refresh | Kit + modules below |
| `WindowLayoutGeometry` | Map layout action + `V` + inset → `CGRect` | Foundation/CoreGraphics only |
| `WindowLayoutApplicator` | Find frontmost resizable window; read/write AX position & size; map failures to errors | AppKit/AX |
| `WindowLayoutHistory` | Store one restore snapshot per window key (`pid` + AX window identifier / role-stable id) until `restore` or window invalidation | Applicator identity keys |
| `WindowLayoutStore` | Persist inset and any phase-1 toggles via `PluginRuntimeContext.storage` | PluginKit storage |

## Layout actions and geometry

Coordinate space: the **visible frame** `V` of the screen that currently contains the target window (menu bar / Dock excluded). Always relative to the window’s screen — not the mouse’s screen.

Before applying a layout (except `restore`), if no snapshot exists for that window, save current frame to history.

| Action id | Label (zh) | Result |
|-----------|------------|--------|
| `maximize` | 最大化 | Fill `V` (not macOS Stage Manager / fullscreen Space) |
| `almost-maximize` | 接近最大化 | `V` inset by configurable `inset` (default 8 pt) |
| `left-half` / `right-half` / `top-half` / `bottom-half` | 半屏 | Half of `V` |
| `center-half` | 中间半屏 | Width `V.w/2`, height `V.h`, horizontally centered |
| `left-third` / `center-third` / `right-third` | 三分之一 | Width `V.w/3` |
| `left-two-thirds` / `right-two-thirds` | 三分之二 | Width `2*V.w/3` |
| `top-left-quarter` | 左上 1/4 | Top-left quadrant of `V` |
| `top-right-quarter` | 右上 1/4 | Top-right quadrant of `V` |
| `bottom-left-quarter` | 左下 1/4 | Bottom-left quadrant of `V` |
| `bottom-right-quarter` | 右下 1/4 | Bottom-right quadrant of `V` |
| `grow` / `shrink` | 放大 / 缩小 | Scale about center by ×1.1 / ÷1.1, clamped inside `V` |
| `center` | 居中 | Keep size, move to center of `V` |
| `restore` | 恢复 | Restore last pre-layout snapshot; clear snapshot on success; disabled when none |

Rules:

- Snap frames to integer points; enforce minimum size **200×120** pt after clamping
- Subsequent layout actions on the same window **keep** the original snapshot until `restore` (so restore always returns to pre-layout, not the previous preset)
- Clamp grown/shrunk rects so they remain inside `V`
- No frontmost resizable window, or missing Accessibility → user-visible error on panel; shortcuts fail closed and may trigger permission guidance
- Fullscreen Space / non-settable windows → readable error, no crash

## Interaction

- **Feature panel**: expandable row; grouped declarative buttons for the actions above
- **Shortcuts**: one `PluginShortcutDefinition` per action id; unbound by default; host records bindings
- **Settings**: `PluginSettingsPage.form` with almost-maximize inset slider (0–40 pt, default 8) plus host-rendered shortcut and permission sections
- **Category**: `productivity`
- **Permissions**: `accessibility`; implement `AccessibilityPermissionRefreshing`

## Lifecycle and safety

- `activate`: wire shortcuts / observers as needed
- `deactivate` with cleanup when required: drop transient history if appropriate; no leftover global event taps in phase 1
- Do not leave windows in a broken state on failure; failed AX writes leave the previous frame

## Testing

- Unit-test `WindowLayoutGeometry` with fixed `V` for halves, thirds, quarters, grow/shrink clamp, center, almost-maximize
- Plugin tests: control ids, disabled `restore`, permission-denied panel state, using a fake applicator
- Manual AX verification on macOS (documented); Windows hosts cannot run the app locally

## Phase 2 (documented only)

- Edge-drag snap with preview overlay (likely Input Monitoring)
- One-click two-window left/right split with an explicit pairing rule

## Success criteria

- User can apply every phase-1 action from the feature panel on a normal resizable window
- User can bind and invoke the same actions via global shortcuts when Accessibility is granted
- Restore returns the window to the pre-layout frame when a snapshot exists
- Plugin can be disabled/uninstalled without affecting `WindowSwitcher` or host stability

## Open decisions (resolved)

- Layout set: Pane-like full common set
- Triggers: panel + shortcuts (no edge drag in phase 1)
- Multi-display: window’s current screen
- Packaging: independent plugin (approach A)
