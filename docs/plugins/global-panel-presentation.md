# Global panel presentation

Global panels own keyboard focus without normally taking application activation.
Settings remains an ordinary application window. Opening a global panel must not
open Settings, move its Space, or invoke a background settings refresh.

## Shared policy

`PluginPanelPresentation` supplies the nonactivating construction mask, transient
Space/Stage Manager behavior, and AppKit ordering safety. Set the mask when creating
an `NSPanel`; do not toggle nonactivation on an existing window. Subclasses accept
key status but refuse main-window status. Preserve each surface's intentional level,
geometry, and content. A persistent workspace may retain its move-to-active-Space
policy instead of joining every Space.

`PluginPanelDismissalMonitor` handles panel focus loss, local/global outside clicks,
and application switches without depending on host activation. Dismissal is deferred
and generation-checked so a temporary focus transfer or an old event cannot close a
reopened panel. Sheets, native menu tracking, IME candidate interaction, and
caller-owned shortcut recording protect the session. End monitoring before ordering
the panel out. Outside interaction dismisses without reactivating the original app.

`PluginPanelFocusRestoration` captures an origin once per presentation. Ordinary
nonactivating cancellation needs no application activation. A compatibility
interaction that deliberately acquires host focus can restore the origin on
cancellation, but not after an explicit target handoff or external focus change.
Do not hide the entire application to dismiss a single panel.

These additive APIs require host 1.3.1 and retain PluginKit v6 compatibility.

## Surface audit

| Surface | Policy |
| --- | --- |
| Global command palette | Shared nonactivating presentation and dismissal; recording and confirmation protection |
| Action Grid | Shared presentation and dismissal; retains pointer debounce and grid-owned confirmation |
| Window Switcher | Shared presentation in all modes; explicit preview click retains gesture activation compatibility; selection owns target activation |
| Clipboard History | Nonactivating persistent workspace; keeps original paste target and nested action palette; losing key focus invalidates filters; keyword expansion excludes typing owned by host panels |
| Menu-bar popover | Native anchored popover without explicit application activation; keeps existing sibling-window and editing dismissal coordinator |
| Shortcut recorder | Native popover anchored to its owning control; suspends transient-parent dismissal |
| Translator, secondary menu panels, menu-bar detail panels, HUDs, snap guides, screenshot outlines | Already nonactivating; keep their existing specialized lifecycle |
| Settings, task confirmations, file/save dialogs, Launchpad, physical clean mode | Retain task-specific activation and safety behavior; these are not interchangeable with transient command panels |

Menu-bar search and the global shortcut open the standalone command palette.
Settings-local Command-K retains the embedded search surface. Explicit navigation
from either palette to a settings destination opens and activates Settings.

## Validation

Run focused panel, command-input, shortcut-recording, Window Switcher, clipboard,
and presentation-safety tests before repository script tests and binary compatibility.
Native tests should verify keyboard input, marked text, temporary focus transfer,
outside dismissal, stale-event rejection, and untouched foreground application.

Physical acceptance must cover Settings closed/background/another Space, full screen,
Stage Manager, multiple displays, Chinese IME candidate clicks, preview pinch/pan,
context menus, shortcut recording, confirmation cancellation, and paste into the
original target. Synthetic input and window-property assertions do not establish
physical gesture or Space-transition behavior.

### Local verification, 2026-09-20

The Debug macOS arm64 build and focused regression run passed on macOS 27.0:
651 XCTest cases passed, with no failures and three opt-in appearance-capture
cases skipped. Coverage includes shared dismissal, native text input, IME composition,
settings routing, Window Switcher selection and preview handling, clipboard keyboard
and paste paths, shortcut control compatibility, and window-ordering safety.
All 270 repository script tests, changelog validation, whitespace checks, and the
PluginKit v6 frozen-client binary compatibility check passed. This is local automated
evidence; the physical acceptance matrix above remains outstanding.
