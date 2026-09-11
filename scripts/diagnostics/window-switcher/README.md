# Window Switcher native diagnostic

This optional macOS diagnostic validates production Window Switcher code against synthetic Chrome windows. It requires Google Chrome, Node.js 22 or later, Xcode, and pre-existing Accessibility and Screen Recording authorization for the launching environment. It does not request permissions, change input sources or Spaces, install MacTools, or touch a personal Chrome profile.

First build the unsigned plugin from the repository root:

```sh
make generate
xcodebuild -project MacTools.xcodeproj -scheme WindowSwitcherPlugin -configuration Debug \
  -derivedDataPath build/WindowSwitcherRedesign CODE_SIGNING_ALLOWED=NO build -quiet
```

Then run the diagnostic while no other native UI tests are running:

```sh
node scripts/diagnostics/window-switcher/chrome.mjs
```

If necessary, set `DEVELOPER_DIR` to your Xcode installation. A custom build-products directory can be supplied as the first argument to `chrome.mjs`.

The driver compiles `Probe.swift` against the built plugin, creates a temporary Chrome profile, verifies the browser PID before issuing browser commands, and opens 1/10/30/60 windows with identical synthetic titles. It asserts stable enumeration, one-window preview capture, exact activation, window recency including a focus change outside the catalog, nonactivating chooser cancellation, minimized/hidden restoration, and closing precisely one selected window. It briefly brings the fixture to the front, then restores the application that was frontmost before the action checks. The driver closes only its verified fixture browser and removes its temporary profile after that process exits.

The reported scan and panel-show durations are local observations, not end-to-end hotkey latency guarantees. This diagnostic does not prove physical keyboard delivery, IME candidate behavior, save-dialog cancellation, fullscreen, or multi-Space/display compatibility. A denied permission or unavailable platform feature fails the assertions rather than being reported as a successful check. Logs contain fixture counts and outcomes; previews are not saved to disk.
