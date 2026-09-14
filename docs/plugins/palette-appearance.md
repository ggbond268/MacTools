# Floating palette appearance

Command Palette and Clipboard History use `PluginPaletteSurface` from PluginKit. Clipboard History's action and queue companion palettes use the same surface. The main menu-bar panel retains its existing theme; an optional glass theme remains a separate proposal.

## Ownership and rendering

- The existing `PluginPaletteSurface` initializer remains unchanged. `PluginPaletteColors.selectedText` is introduced in the upcoming host 1.3.1 and recorded in the minimum-host inventory. Clipboard History already requires host 1.3.1, so its manifest does not change. The plugin must ship with that updated host framework; the published 1.3.0 host is below its minimum version.
- The background uses a native AppKit `NSGlassEffectView` with regular style on macOS 26 and later, bridged into SwiftUI. Pointer acceptance found that `Color.clear.glassEffect` prevented the borderless Command Palette's handle from dragging, while both the original material and the AppKit bridge moved under the same injected input. The local Window Switcher prototype informed the native AppKit approach; its files were not changed. Existing hosted content stays outside the background and retains its identity.
- There is one glass surface per panel, with no custom tint, opacity overlay, interactive glass, polling, private preference keys, or additional setting. Native glass owns the macOS 27 appearance control and live system updates. Layout and input content remain outside the background branch, preserving their identity when accessibility settings change.
- Reduce Transparency selects an opaque semantic background. macOS 14 and 15 use native material. Increase Contrast strengthens panel, selected-row, control, and image-preview boundaries. Selection text preserves the system's preferred foreground when it meets 4.5:1 contrast against the opaque selection background; otherwise it uses black or white. This also protects yellow accents, selected subtitles, and shortcut labels. Colors resolve again for the current appearance.
- Command Palette clips its backdrop to the visible rounded silhouette and applies one shared content shadow in both Settings and standalone presentations. The standalone panel uses a plain AppKit hosting container, disables automatic SwiftUI safe-area/sizing behavior, and has no second window shadow around its transparent padding. Clipboard keeps its existing hosting and native shadow.
- The host retains Command Palette routing, focus restoration, drag/snap coordination, and placement. Clipboard History retains its panel lifetime, explicit drag handle, native resizing, per-display placement, search model, previews, and action routing. Glass never tints captured previews or changes clipboard payloads.

Apple references: [custom SwiftUI glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [macOS 27 AppKit design updates](https://developer.apple.com/videos/play/wwdc2026/289/).

## Repeatable validation

Start with `PluginPaletteSurfaceTests`, `ClipboardHistoryWindowStyleTests`, and `ClipboardHistoryDetailActionStyleTests`. The surface regression checks opaque rendering and preserves the native field editor, marked text, hit testing, and window frame across live appearance and surface changes. Follow with routing, keyboard, placement, preview, and panel-update tests. Run `make script-tests` and `make ci` for the shared PluginKit implementation.

Three optional XCTest methods open the production panels with synthetic data and isolated settings. Set `TEST_RUNNER_MACTOOLS_PALETTE_CAPTURE_DIR` to an absolute local output directory when invoking `xcodebuild test`, and select:

```text
-only-testing:MacToolsTests/AppWindowRouterTests/testCaptureCommandPaletteAppearanceForReview
-only-testing:MacToolsTests/AppWindowRouterTests/testCaptureSettingsCommandPaletteAppearanceForReview
-only-testing:MacToolsTests/ClipboardHistoryPluginTests/testCaptureClipboardAppearanceForReview
```

For the actual composited glass over the synthetic backdrop, run the driver from an unlocked desktop whose invoking terminal already has Screen Recording access:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  python3 scripts/e2e/capture-palette-appearance.py build/PaletteAppearance/review
```

For an interactive inspection of the synthetic Command Palette, also set `TEST_RUNNER_MACTOOLS_PALETTE_INTERACTIVE_REVIEW=1` when running its XCTest directly. After the automatic checks it holds the light palette open for 60 seconds for pointer and keyboard review, then closes it.

The output directory must be new. The helper uses the last connected display for review and captures the panel rectangle above an owned synthetic background. Keep unrelated windows and alerts clear of that display: rectangle captures include anything overlapping the panel. A final frame on the other display is recorded separately when available. The driver runs the tests sequentially so native field editors do not compete for key focus.

Add `--native-drag` to exercise each production drag handle with injected pointer events. This requires existing pointer-event access and moves only windows owned by that test build. The test supplies the native handle's coordinates, and the driver fails if the window does not move. The resulting `.drag.json` files distinguish this check from programmatic movement and physical hardware input. Idle CPU sampling waits two seconds after reopening to avoid measuring the opening transition.

Without the driver, the helper uses ScreenCaptureKit if access is available, or an in-process view image otherwise. Window-only and in-process images do not establish the appearance of WindowServer glass over the real backdrop; `capture-report.json` identifies the method. Capture tests are skipped during ordinary CI runs. They never use the personal clipboard, modify global appearance settings, or execute search results. Live System Settings acceptance is a separate, explicitly recorded session.

## Native acceptance checklist

Record the OS build, system accent, display count, capture method, and settings actually exercised. App appearance overrides and a programmatic Reduce Transparency input are useful regression checks, but do not establish end-to-end system-settings acceptance.

- With both panels open, change the macOS 27 Liquid Glass preference through System Settings; verify live changes without losing query, selection, composition, or placement.
- Check Light and Dark with each supported system accent, Increase Contrast, and Reduce Transparency; repeat on bright, dark, and detailed backgrounds. Inspect selected subtitles, shortcut badges, disabled buttons, errors, and image/rich-text borders.
- Open, type, navigate with arrows and number shortcuts, use Tab, dismiss with Escape and outside click, then reopen. Exercise real IME composition and VoiceOver.
- Drag using each explicit handle, snap, resize Clipboard History, and reopen. Repeat across physical displays, disconnection, fullscreen, and Spaces/Stage Manager.
- Compare idle CPU, cold/warm opening, search/scroll latency, and physical dragging on equivalent before/after builds. Programmatic window moves measure only dispatch/layout work, not physical drag or WindowServer/GPU frame pacing.
- Run native fallback acceptance on macOS 14/15 and native glass acceptance on macOS 26. Building with a macOS 14 deployment target does not establish runtime behavior on those systems.

The local validation report under `build/PaletteAppearance/` records the results and remaining gaps for this implementation.
