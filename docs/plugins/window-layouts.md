# Window Layouts Plugin

Window Layouts publishes focused-window commands as canonical MacTools actions. The host owns discovery, action-backed Run Links, Action Grid, Trackpad Gestures, workflow execution, availability, permissions, shortcut persistence, and conflicts. The plugin owns geometry, shortcut preset selection, and persistent custom commands.

## Product Scope

Window Layouts is a command-first companion to macOS window tiling, not a replacement window manager. macOS continues to own pointer-driven edge snapping, its green-button layout menu, and interactive tiling previews. The plugin focuses on deterministic actions that users can invoke consistently from every MacTools action surface.

The supported product boundary is:

- Explicit focused-window placement and restoration
- Incremental width and height adjustments
- Explicit custom single-window commands
- Explicit movement between displays
- Optional modifier-key dragging of the window beneath the pointer
- Optional centered alignment guides and release-time snapping for external windows
- Shortcuts, Run Links, Unified Search, Action Grid, Trackpad Gestures, and manually started workflows

Modifier Drag is opt-in and requires an exact modifier-key combination. Centered window guides are a separate opt-in feature for ordinary window dragging. macOS continues to own edge snapping. It does not continuously manage window positions or automatically apply layouts in response to app launches, window creation, focus changes, display topology, wake, or unlock.

Broader window-manager features remain out of scope: automatic tiling, per-app or title-based rules, visual layout editors, directional focus and swapping, stash or pin modes, window lifecycle commands, cloud sync, dedicated layout import/export, and configuration through a CLI.

## Built-in Commands

- Toggle native macOS full screen
- Maximize, maximize height, maximize width, center, and Reasonable Size
- Increase or decrease width and height in 50-point steps, subject to window and display limits
- Left, right, top, and bottom halves
- Four corners
- First, first two, center, last two, and last thirds
- First, second, third, and last fourths
- Top-left, top-center, top-right, bottom-left, bottom-center, and bottom-right sixths
- Move to any screen edge while preserving size
- Move proportionally to the next or previous display
- Restore the previous frame for each live window

Reasonable Size uses 60% of the current safe visible frame, capped at 1025 × 900 points. The gap setting applies to both desktop edges and shared seams, so a configured 12-point gap remains 12 points between adjacent tiled windows. Optional half-screen cycling advances each left, right, top, or bottom command through one-half, two-thirds, and one-third on the current display, then wraps to one-half. Cross-display movement remains an explicit command.

Successful global-shortcut and Trackpad Gesture commands can optionally show a compact, short-lived confirmation HUD. This is disabled by default to keep repeated window movement quiet. Failures from those headless surfaces always use the standard feedback HUD so an unavailable or rejected command is not silent. Interactive surfaces continue to report results in their own UI.

## Modifier Drag

Modifier Drag is disabled by default and requires Accessibility permission. Once enabled, hold exactly the configured modifiers and move the pointer beyond the small activation dead zone to move the compatible window beneath it. Dragging preserves the window's size and does not click, raise, or focus it. Releasing a required modifier, adding another modifier, pressing a regular key, or pressing a mouse button cancels the gesture. Release all modifiers before starting another gesture.

The separate drag indicator is enabled by default. It appears beside the pointer after a short arming delay, follows the pointer during an active drag, and briefly explains failures. Turning it off suppresses all Modifier Drag indicators without disabling dragging or changing command feedback. Temporary Accessibility write delays in busy apps are retried during the gesture; unavailable or rejected windows still report a failure.

## Centered Window Guides

Centered window guides are disabled by default and require Accessibility permission. Enable them in Window Layouts to see the shared dashed guides while dragging a standard external window. Guides highlight per axis within 20 points, with 4 points of hysteresis. Releasing near both centered axes moves only that window to the centered target and preserves its size. The window gap setting does not alter this target.

The existing listen-only Modifier Drag event tap serves both features. It never intercepts input. A mouse-down snapshot captures just the topmost target; subsequent AX work runs on the Accessibility worker and coalesces at a 16 ms cadence. A pointer history capped at 128 samples and 120 ms keeps guides responsive when input overtakes AX reads. Temporary position lag may recover within 120 ms; release sampling uses only the final pointer and never historical positions to authorize a snap. Feedback requires a drag event and actual position changes that follow the pointer without a size change. Ordinary clicks, text selection, unrelated programmatic movement and resizing do not activate guides. MacTools windows use their dedicated coordinators and are excluded here.

Full-screen, minimized, hidden, invalid, immovable and nonstandard/transient windows are excluded. Effectively maximized means all four frame components match the usable display frame within 3 points, rather than an area-percentage heuristic. Oversized windows are excluded to avoid resizing them. Usable frames respect the menu bar, Dock and the existing Stage Manager option. Display/Space changes, sleep, session deactivation, keyboard cancellation, permission loss and target disappearance dismiss guides. Release rereads the same target and validates its current eligibility and frame immediately before a single position write; no focus fallback or retry is allowed.

The shared snap APIs require host 1.3.1 or later. Window Layouts and Clipboard History declare that minimum so their updated packages cannot load against the older 1.3.0 PluginKit framework.

Manual acceptance must cover native and custom title bars in several apps, mouse and trackpad input, a window already centered, large but nonmaximized windows, all resize edges, text selection, multiple displays with different scaling and vertical arrangements, Spaces, Stage Manager on either side, Dock/menu-bar changes, permission revocation and a target closing before release. Automated tests exercise policy, event arbitration and asynchronous release safeguards; they do not establish physical-input acceptance.

## Stage Manager

When Stage Manager avoidance is enabled, the plugin reads on-screen Dock-owned window geometry for every action and removes a visible thumbnail strip from the target display's safe frame. No fixed display width or cached topology is used. If no visible strip is found, the normal `NSScreen.visibleFrame` remains unchanged.

## Custom Commands

Custom commands persist a stable UUID-backed action identity and support:

- Current, fixed-point, or display-relative width and height
- Nine anchored positions
- Horizontal and vertical offsets
- Duplication
- Optional Run Link exposure
- Global shortcut assignment through the plugin shortcut section

Changing a custom command preserves its action identity, so existing surfaces and links continue to resolve it. Deleting one makes its old action reference unavailable.

## Window Eligibility

The focused-window path captures an exact application target before MacTools opens a transient action surface. External applications use their focused window with a main-window fallback. When the ordinary MacTools Settings window is genuinely frontmost, its exact window number is captured and the same-process `NSWindow` is moved or resized directly; Unified Search, Action Grid, confirmation panels, and feedback HUDs are never selected as targets. This lets an action invoked over Settings affect Settings, while an action surface opened from another app continues to affect that app. External-window movement requires a settable Accessibility position, resizing requires a settable size, and native full screen requires a settable `AXFullScreen` attribute.

Geometry uses Accessibility's global top-left coordinate space. The current display is selected by largest window-frame intersection, with nearest-display fallback for windows outside all displays. Adjacent displays are ordered deterministically by horizontal position, then vertical position. Display movement preserves relative size and available-travel position where possible, then clamps inside the destination safe frame. Placement reapplies size after position for applications that only accept expansion once a window has moved. It then allows up to 250 milliseconds for asynchronous Accessibility frame updates, with one bounded retry, before verifying the resulting frame. Geometry commands share a FIFO execution gate so rapid shortcuts cannot overwrite one another while an earlier frame is still settling. If an application still rejects the requested size, the command reports that result instead of claiming success.

## Manual Verification

Before release, verify:

- The Dock on the left, right, and bottom
- Stage Manager thumbnails on both sides and with auto-hide
- Displays arranged left, right, above, and below the primary display
- Mixed logical resolutions and scale factors
- Full-screen, non-movable, non-resizable, closed-during-execution, and revoked-permission windows
- MacTools Settings as the frontmost target, including commands invoked through Unified Search and Action Grid
- An external window while MacTools Settings remains visible and a transient action surface is open
- Optional success feedback enabled and disabled for global shortcuts and Trackpad Gestures, plus always-visible failure feedback
- Modifier Drag with its indicator enabled and disabled: delayed arming, active pointer tracking, failure messages, and movement without a focus change
- Modifier Drag cancellation on modifier release, extra modifiers, regular keys, and mouse buttons; retry after releasing all modifiers
- Modifier Drag in a busy application, including temporary write delays and a window that becomes unavailable
- Rapidly alternate top, bottom, left, and right halves in an application with asynchronous resizing, such as ChatGPT, and confirm every command completes in order without a false size error
- Run Links disabled for individual custom commands
- Control–Option, Option–Command, Control–Option–Command, and None shortcut presets: selecting changes only the preview, conflicts disable Apply, Cancel preserves assignments, and confirmed Apply replaces only the listed Window Layout shortcuts
