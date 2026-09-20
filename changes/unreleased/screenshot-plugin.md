---
release: plugin
type: added
area: Screenshot
---

- Add Screenshot with region and window selection, annotations, local text and QR recognition, pinned images, and scrolling screenshots.
- Quick Capture copies a selection immediately, and macOS 15 or later supports silent region recording.
- Capture starts through explicit foreground controls or working global shortcuts; saved files default to `~/Desktop/screenshot` and remain when the plugin is removed.
- QR masking fully covers recognized codes; scrolling screenshots process in the background with bounded output size.
- Improve capture visibility with clear dimming, accent-colored target outlines, and balanced toolbar spacing with capsule-shaped mode and recognition actions.
- Expand the capture magnifier with separate coordinates, RGB or HEX values, Tab format switching, and Command-C copy that closes capture.
- Keep hover highlights and the mode bar on the pointer display when moving between screens, clearing stale previews without discarding existing selections.
- Enlarge the top mode bar and place it near the screen edge, with a matching grip for horizontal dragging that stays on screen and avoids the camera housing.
- Recognize visible menus, menu bar popovers, and standard floating panels as window-selection targets without passing capture clicks to their controls.
- Preserve translucent menus and popovers, including native edge highlights and shadows within the capture region, in previews and exports. Capture overlays appear without panel zoom animation.
- Reuse capture controls and acquire display snapshots concurrently for responsive selection, releasing frozen images when selection ends.
- Improve fast selection dragging and keep the final region aligned with the mouse release position.
- Fix selection dragging from the exact top screen edge without activating the app or changing menu bar behavior.
