# Window Switcher development

The redesign uses per-process Accessibility workers and a native, nonactivating searchable chooser. Activation targets use live AX identity; capture metadata never determines the action destination. Screen Recording permission is optional for core switching.

See the [interaction contract and acceptance record](../superpowers/specs/2026-09-10-window-switcher-redesign.md) and [isolated Chrome diagnostic](../../scripts/diagnostics/window-switcher/README.md). The diagnostic runs against a temporary profile, fails on unexpected native outcomes, and does not install a packaged plugin.

The plugin manifest targets PluginKit v6 and publishes both All Windows and Current App Windows actions. The host shortcut-resolution change and plugin listener should be reviewed and released together. Existing custom or cleared shortcuts remain authoritative, and selecting the companion preset changes inherited defaults. Do not claim release readiness from model tests alone; record physical IME, fullscreen, Spaces, displays, and save-dialog acceptance separately.

The chooser now consumes `PluginWindowSnapCoordinator` for its own drag handle, so its minimum host is 1.3.1. This is independent of Window Layouts' external-window centered guides. Capture inventory is retained only for two seconds and reused only with exact window IDs; failed/missing matches invalidate it, and permission checks gate captures and display.

Keyboard navigation: In Search and Select, Command-1 through Command-9 immediately opens the numbered fully visible windows in either layout; Return activates the highlighted window. Command-Option-1/2 selects grid/list, Command-Shift-1/2 selects scope, Command-F focuses search, Command-P toggles previews, Command-D opens display filters, Command-K opens actions/help, and Escape dismisses. Number shortcuts remain selection-only during cycling and are suppressed during marked-text composition.

Window Switcher remembers the last grid/list choice. Unselected cards are borderless, and number badges appear only during persistent selection. The highlighted app scope is unavailable with fewer than two windows. Unnamed compositor surfaces require Accessibility confirmation, preserving real untitled windows across Spaces.

Window Switcher uses native Liquid Glass on macOS 26 and later, following system appearance and accessibility preferences, with a translucent-material fallback on older systems. Grid selection uses a soft accent fill without an outline.

Grid cards show the app icon and window title, with app identity in the selected preview heading. A subtle divider separates previews from both layouts. A fixed mode indicator explains release-to-switch versus persistent Search & Select; cycling remains active until the user types or focuses Search. No timer or presentation control changes the release behavior. Search stays open until Return or dismissal.

Search matches use a contrasting text/background pair in both themes. Selection, shortcut hints, preview frames, and action errors remain readable with accessibility contrast settings. App-name-only search matches reveal their app context in the grid.

Window Switcher preserves Direct Keys and its editable assignments when upgrading stable profiles. New installations default to Search and Select; switching the default mode is explicit. Legacy keys open their assigned window immediately, and focusing Search enters search for that invocation. Migrated profiles keep Command-W/Command-Q free of close/quit actions; those actions remain available in the options and context menus. Experimental local search profiles retain their chosen search behavior.

Right-click or Control-click a window for Switch to Window, Close Window, and Quit App; Shift-F10 opens these actions for the highlighted window. While the chooser is open, the current-app shortcut narrows to the highlighted app, repeated presses cycle its windows, and the all-windows shortcut returns to the full scope. The scope names the app and preserves the current cycling or search behavior. Custom shortcuts work from the results; ordinary editing chords remain available while typing in Search. Clickable up/down indicators reveal additional grid rows when the scrollbar is hidden.

Window Switcher filters invisible compositor-only surfaces with no Space membership while preserving live Accessibility windows and other-Space windows. Native app activation handles apps that acknowledge Accessibility activation without coming forward. Direct Keys has larger editable badges and a Change Key context action.

Direct Keys supports clicking a key badge or choosing Change Key in both grid and list layouts. Slim, wide arrow buttons reveal additional grid rows. Window switching verifies actual foreground and exact window focus across differing app activation behavior, with no app-specific exceptions.

Window Switcher matches the command palette’s rounded search field and full-height close button, with options beside the view controls. Direct Keys editing shows a prominent recording panel near the top; selecting another card preserves its clickable key control, and context menus keep the chooser open while choosing an action.
