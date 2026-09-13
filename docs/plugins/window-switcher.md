# Window Switcher development

The redesign uses per-process Accessibility workers and a native, nonactivating searchable chooser. Activation targets use live AX identity; capture metadata never determines the action destination. Screen Recording permission is optional for core switching.

See the [interaction contract and acceptance record](../superpowers/specs/2026-09-10-window-switcher-redesign.md) and [isolated Chrome diagnostic](../../scripts/diagnostics/window-switcher/README.md). The diagnostic runs against a temporary profile, fails on unexpected native outcomes, and does not install a packaged plugin.

The plugin manifest targets PluginKit v6 and publishes both All Windows and Current App Windows actions. The host shortcut-resolution change and plugin listener should be reviewed and released together. Existing custom or cleared shortcuts remain authoritative, and selecting the companion preset changes inherited defaults. Do not claim release readiness from model tests alone; record physical IME, fullscreen, Spaces, displays, and save-dialog acceptance separately.

The chooser now consumes `PluginWindowSnapCoordinator` for its own drag handle, so its minimum host is 1.3.1. This is independent of Window Layouts' external-window centered guides. Capture inventory is retained only for two seconds and reused only with exact window IDs; failed/missing matches invalidate it, and permission checks gate captures and display.

Keyboard navigation: In Search and Select, Command-1 through Command-9 immediately opens the numbered fully visible windows in either layout; Return activates the highlighted window. Command-Option-1/2 selects grid/list, Command-Shift-1/2 selects scope, Command-F focuses search, Command-P toggles previews, Command-D opens display filters, Command-K opens actions/help, and Escape dismisses. Number shortcuts remain selection-only during cycling and are suppressed during marked-text composition.

Window Switcher remembers the last grid/list choice. Unselected cards are borderless, and number badges appear only during persistent selection. The highlighted app scope is hidden with fewer than two windows, except while that app filter is already active. The same flat scope control renders one or two choices. Unnamed compositor surfaces require Accessibility confirmation, preserving real untitled windows across Spaces.

Window Switcher uses native Liquid Glass on macOS 26 and later, following system appearance and accessibility preferences, with a translucent-material fallback on older systems. Grid selection uses a soft accent fill without an outline.

Grid cards show the app icon and window title, with app identity in the selected preview heading. A subtle divider separates previews from both layouts. A fixed mode indicator explains release-to-switch versus persistent Search & Select; cycling remains active until the user types or focuses Search. No timer or presentation control changes the release behavior. Search stays open until Return or dismissal.

Search matches use a contrasting text/background pair in both themes. Selection, shortcut hints, preview frames, and action errors remain readable with accessibility contrast settings. App-name-only search matches reveal their app context in the grid.

Window Switcher preserves Direct Keys and its editable assignments when upgrading stable profiles. New installations default to Search and Select; switching the default mode is explicit. Legacy keys open their assigned window immediately, and focusing Search enters search for that invocation. Migrated profiles keep Command-W/Command-Q free of close/quit actions; those actions remain available in the options and context menus. Experimental local search profiles retain their chosen search behavior.

Right-click or Control-click a window for Switch to Window, Close Window, and Quit App; Shift-F10 opens these actions for the highlighted window. While the chooser is open, the current-app shortcut narrows to the highlighted app, repeated presses cycle its windows, and the all-windows shortcut returns to the full scope. The scope names the app and preserves the current cycling or search behavior. Custom shortcuts work from the results; ordinary editing chords remain available while typing in Search. Clickable up/down indicators reveal additional grid rows when the scrollbar is hidden.

Window Switcher filters invisible compositor-only surfaces with no Space membership while preserving live Accessibility windows and other-Space windows. Native app activation handles apps that acknowledge Accessibility activation without coming forward. Direct Keys has larger editable badges and a Change Key context action.

Direct Keys supports clicking a key badge or choosing Change Key in both grid and list layouts. Slim, wide arrow buttons reveal additional grid rows. Window switching verifies actual foreground and exact window focus across differing app activation behavior, with no app-specific exceptions.

Window Switcher uses a full-width rounded search field with separately laid-out icon, native text editor, and Clear Search button. Placeholder and editor share the same geometry. Escape dismisses the chooser; Close Switcher in the options menu provides a mouse-accessible alternative without a separate toolbar button. Direct Keys editing shows a prominent recording panel near the top; selecting another card preserves its clickable key control, and context menus keep the chooser open while choosing an action.

### Reliability boundaries

Window actions retain the menu's original target and reject targets that disappeared. A continuously observed AX replacement receives a new public identity even if its compositor number is reused; legitimate fallback-to-AX Space rediscovery retains selection. Activation stops submitting focus changes after an intervening foreground application change. Already submitted system actions cannot be undone.

Discovery includes list processing in its per-app budget and retains an unavailable snapshot when the budget expires. Preview captures remain serial; after a two-second wait the chooser reports unavailability, keeps the occupied capture slot bounded, and resumes the latest pending selection when the system operation returns. Cached previews expire after thirty seconds even when idle. Hidden preview panes do not initiate captures.

## Content-aware chooser sizing

Opening the chooser fits its size to the unfiltered window count, selected grid/list view, and preview setting. Small grids use fewer columns and rows; lists use a narrower row-based layout. Large catalogs scroll within a screen-relative height limit. Search, selection changes, and background metadata refreshes keep the current frame stable. Explicit scope, display, layout, and preview changes recalculate size while preserving the top edge where screen bounds allow it.

Manual sizes are retained for the lifetime of the controller, separately for each grid/list and preview combination. Reset Size in the options menu restores content-aware sizing for the current combination. A missing saved layout defaults to grid; catalog growth never changes the chosen view.

Preview inspection stays within the existing viewport: pinch to zoom up to 4×, drag or use arrow keys while the enlarged preview has focus to pan, and double-click to fit. The preview context menu and options menu offer Zoom In, Zoom Out, and Fit Preview. Search and Select also supports Command-Plus, Command-Minus, and Command-0 unless reserved by existing Direct Keys assignments. Selecting another window resets the preview to Fit.

Normal captures keep their 1,600-pixel maximum edge. Zooming requests one sharper capture per selection, capped at 3,200 pixels and serialized with normal captures. The existing image remains visible during that request or if it fails. Detail captures are not cached across selections, and permission and window-identity validation remain unchanged.
