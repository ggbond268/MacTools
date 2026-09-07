# Panel layout editing acceptance

Run `make panel-layout-ui-tests` on a logged-in macOS desktop with the repository's Xcode toolchain. The check also runs in `make ci` and the GitHub Build workflow.

The runner compiles the production editor, toolbar, grid packing, drag session, native drag source, and scroller into a temporary application with synthetic host/theme interfaces. It opens an isolated popover, drives its native AppKit event queue, and checks:

- Dashboard and Feature Panel in left-to-right and right-to-left layouts.
- A card-body drag, moving to the end and back to the beginning.
- Cancellation outside the reorder canvas, followed by a successful new drag.
- Undo and the visible Done button.

Each scenario runs in a separate process with a watchdog. The runner bounds compilation and execution time, removes its temporary files, and exits unsuccessfully if a scenario fails. It does not load installed plugins, use personal preferences, replace the Debug app, or post global pointer events.

The synthetic host is an interaction fixture, not a persistence test. `PanelLayoutEditorTests` separately exercises the real `PluginHost`, preference-store recreation, hidden-item positions, surface isolation, Undo, body/handle/menu hit testing, and scroll coordinates. `PanelLayoutEditingSessionTests` covers stale completion callbacks, invalidation, Undo eligibility, and insertion boundaries. `PanelLayoutToolbarTests` sends mouse events to the production toolbar. Rendering fixtures attach screenshots to the XCTest result bundle.

A standalone application loop is deliberate. XCTest's async event pumping can initiate a native source without completing its drop; nesting `NSApplication.run()` inside XCTest can hang its runner. Keep native drag acceptance in the separate fixture.

Before marking the feature ready, also check physical mouse/trackpad dragging and drag lock, dragging outside the application, sustained edge scrolling, keyboard navigation, VoiceOver, and Reduce Motion on supported macOS versions. The fixture uses synthetic pointer events and does not establish those hardware/accessibility results.
