# Panel layout editing validation

Run the smallest related model test class:

```bash
make test TEST_FILTER=MenuBarPanelStoreTests
make test TEST_FILTER=PanelLayoutEditingSessionTests
make test TEST_FILTER=PanelLayoutEditorTests
```

The retained tests cover layout persistence, independent placements, moves/removal, cancellation, and Undo. The host tests cover item routing and lifecycle. Reuse those checks rather than recreating the same matrix for every plugin.

The native drag fixture and automated window/layout checks have been removed. For an interaction change, build and run the app, then manually exercise the affected path:

- Add an item, move it within or between panels, remove it, and verify Undo.
- Cancel a drag and confirm that the saved layout has not changed.
- Check scrolling and dropping into an empty panel when those paths change.
- Check keyboard navigation, focus, or accessibility only when the change affects them.

Use representative content and record a short result or recording. Exact spacing, colors, screenshots without review, every span combination, and repeated synthetic pointer sequences do not belong in the routine test suite. See the [core test scope](core-tests.md).
