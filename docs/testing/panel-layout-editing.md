# Panel layout editing acceptance

Default validation uses XCTest for persisted entries, independent widget copies, cross-panel moves and Undo, drag invalidation, viewport mounting, and plugin lifecycle. `MenuBarPanelPresenterTests` retains regressions for deleting the selected panel, editing dismissal, and coordinated resizing; `PanelLayoutEditorTests` checks removal confirmation and entry isolation. Run the smallest affected test class with `-only-testing:MacToolsTests/<TestClassName>`.

Check cosmetic changes visually. Avoid exact padding/color assertions, menu-count checks, screenshot generation without comparisons, and repeating the same behavior through several native click sequences. `PanelLayoutToolbarTests` checks feedback coalescing with explicit timestamps instead of waiting for animation cooldowns.

For changes to native drag routing or hit testing, run `make panel-layout-ui-tests` on a logged-in macOS desktop with the repository's Xcode toolchain. This is an opt-in check, excluded from `make ci` and the GitHub Build workflow. To run one scenario, use `python3 scripts/e2e/run_panel_layout_fixture.py --surface cross-panels` (also accepts `tabs`, `dashboard`, or `features`).

The runner compiles the production editor, toolbar, grid packing, drag session, native drag source, and scroller into a temporary application with synthetic host/theme interfaces. It opens an isolated popover, drives its native AppKit event queue, and checks:

- Dashboard and Feature Panel in left-to-right and right-to-left layouts.
- Tab reordering and cross-panel drag transfer.
- A card-body drag, moving to the end and back to the beginning.
- Cancellation outside the reorder canvas, followed by a successful new drag.
- Undo and the visible Done button.

Each scenario runs in a separate process with a watchdog. The runner bounds compilation and execution time, removes its temporary files, and exits unsuccessfully if a scenario fails. It does not load installed plugins, use personal preferences, replace the Debug app, or post global pointer events.

The synthetic host is an interaction fixture, not a persistence test. `PanelLayoutEditorTests` separately exercises the real `PluginHost`, independent entries, surface isolation, Undo, control isolation, and scroll coordinates. `PanelLayoutEditingSessionTests` covers stale completion callbacks, invalidation, Undo eligibility, and insertion boundaries.

`PanelLayoutEditorTests.testDragPreviewKeepsCardFramesAndDropCanvasStableUntilCommit` mounts mixed-size cards in both layout directions and on both surfaces. It checks that previews and leaving the drop area preserve card frames and canvas bounds, and that committing the move updates the actual layout.

A standalone application loop is deliberate. XCTest's async event pumping can initiate a native source without completing its drop; nesting `NSApplication.run()` inside XCTest can hang its runner. Keep native drag acceptance in the separate fixture.

Before marking the feature ready, also check physical mouse/trackpad dragging and drag lock, dragging outside the application, sustained edge scrolling, keyboard navigation, VoiceOver, and Reduce Motion on supported macOS versions. The fixture uses synthetic pointer events and does not establish those hardware/accessibility results.
