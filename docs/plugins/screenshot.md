# Screenshot

Screenshot brings the local Snap capture and editing implementation into one native MacTools plugin. Install the package through the plugin flow, then open **Screenshot** from its feature panel, unified search, or an optional shortcut. It has no separate menu-bar app, background capture service, or third-party runtime dependency.

Adapted from the [Snap screenshot implementation](https://github.com/idev19/Snap) and integrated with MacToolsPluginKit.

## Capture and edit

- **Capture Screenshot** opens a visible selection interface across connected displays. Drag to select a region or click a highlighted window. Add rectangles, ellipses, lines, arrows, freehand marks, text, numbered tags, mosaic, or blur before copying, saving, or pinning the image.
- **Quick Capture** uses the same selection interface and immediately copies the selected image after selection.
- **Text and QR recognition** processes the frozen selection locally. Recognized content can be edited and copied. Closing the panel, changing the selection or mode, or ending capture prevents an earlier recognition request from publishing its result.
- **Pinned images** stay in a movable window for reference. Use Command-S to save, and Escape or a double-click to close.
- **Scrolling screenshots** sample the selected region while you scroll it yourself. Finish to copy and pin the assembled image, or cancel to discard it. Capture failures are reported; results arriving after the session ends are ignored.
- **Region recording** is available on macOS 15 or later. Choose the recording mode and a region, then start and stop using the visible controls. It saves a MOV file without microphone or system audio. Completion is reported only after the recording output finishes; a timeout or write failure is reported as an error.

Escape closes the active selection interface. Screenshot and Quick Capture shortcuts are unassigned by default and are configured through the host's shortcut settings. While scrolling capture or recording is active, the capture action finishes that session instead of opening another selection interface.

## Permissions and compatibility

The plugin supports macOS 14 or later on Apple silicon and Intel. Region recording additionally requires macOS 15 or later; screenshot editing, recognition, pinning, and scrolling capture remain available on macOS 14.

MacTools owns the Screen Recording permission card (`screen-recording`, kind `screenRecording`). Grant permission from that card when you choose to capture, and follow any macOS instruction to relaunch MacTools. The plugin does not request Accessibility, microphone, or system-audio recording access. Permission denial or revocation must leave a clear recovery path in the host.

## Privacy and retention

Screen images, visible window geometry, recognized text, and codes may contain sensitive information. Capture starts only through an explicit foreground action with a visible selection interface. The two canonical actions do not support external Run Links, automatic rules, or App Intents. The plugin does not capture on startup or run unattended screenshot jobs.

Capture, recognition, editing, and image assembly use Apple frameworks locally. The plugin has no upload, network service, or telemetry. Choosing to open a recognized link explicitly hands that URL to the user's browser; screenshots and recognized text are not sent to a service by the plugin.

Screenshots are copied to the system clipboard unless you choose a save operation. Saved images use PNG; recordings use MOV. The default destination is the Desktop, and the plugin's settings can select another folder. The selected folder is stored in plugin-scoped preferences. Exported files remain until you manage or delete them yourself; clipboard content remains subject to macOS and other clipboard applications.

Disabling the plugin or ending its session closes its capture UI and prevents pending work from publishing stale results. Disabling also closes pinned images and auxiliary windows. Unsaved edits are discarded. If recording has already created a file, interruption or an error can leave an incomplete MOV file in the selected output folder; inspect or remove it yourself.

The package declares `uninstallDataPolicy: removePrivateData`. The host removes the plugin's private preferences, support, cache, and temporary data on uninstall. Cleanup does not delete screenshots or recordings exported to a user-selected folder, and it does not clear the system clipboard or revoke MacTools' shared Screen Recording permission.

## Plugin contract

| Field | Value |
| --- | --- |
| Package / provider ID | `screenshot` |
| Factory | `ScreenshotPlugin.ScreenshotPluginFactory` |
| Bundle / scheme | `Screenshot.bundle` / `ScreenshotPlugin` |
| Initial package version | `1.0.0` |
| Compatibility | PluginKit 6, MacTools 1.3.0 or later |
| Host surfaces | Primary panel and settings form; no component panel |
| Permission | `screen-recording` |
| Canonical actions and shortcut IDs | `capture`, `quick-capture` |
| Action parameters | None |
| Action policy | Safe, foreground interactive, external invocation unavailable, automatic execution ineligible |

The source manifest contains all 11 marketplace metadata locales. The plugin string catalog provides Simplified Chinese and English UI copy, with complete translations for the metadata and action descriptions referenced by the manifest. The host continues to own permission guidance, shortcut assignment, action discovery, and plugin lifecycle.

## Development and validation

Plugin targets are discovered from `Plugins/Screenshot/plugin.json`. The plugin's `project.yml` only adds ScreenCaptureKit, Vision, CoreImage, UniformTypeIdentifiers, and QuartzCore linker flags. Do not modify root project targets or generated plugin configuration to register it.

After preparing local signing settings, generate the project and build the plugin:

```sh
make generate
make build-plugin PLUGIN=Screenshot
```

Run script checks for source-manifest projection, generated project configuration, and PluginKit minimum-host compatibility:

```sh
make script-tests
```

Run the adjacent Screenshot test classes and `PluginRuntimeActionSnapshotTests` through the generated host test target, limiting execution with `-only-testing:MacToolsTests/<TestClassName>`. Use injected images, permission checks, and asynchronous capture/recognition closures in tests; tests must not capture the real desktop or delete user files.

Before release, check region and window selection on a single display and mixed-scale multiple displays; annotations and PNG output; OCR and QR success, failure, and cancellation; pin closure; repeated scrolling start/finish/cancel; Screen Recording denial and revocation; plugin deactivation during pending work; and successful and failed recording finalization on macOS 15 or later. Confirm macOS 14 hides or explains the unavailable recording mode, optional shortcuts remain unassigned, and uninstall preserves exported files. Verify translated labels and errors in English and Simplified Chinese.
