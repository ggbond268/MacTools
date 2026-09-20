# Duo Status

Duo Status (`duo-status`) is a PluginKit v6 plugin for MacTools 1.3.1 or later. It displays a 24-point menu-bar icon for the Mac's battery, Wi-Fi signal, and network connection. The implementation is adapted from the artwork and monitoring in [PR #434](https://github.com/ggbond268/MacTools/pull/434).

## Use

Install the plugin from the Marketplace. **Duo Status > Menu Bar > Display Mode** offers **Separate Icon** (default) and **Replace App Icon**. There is no additional visibility switch, Dashboard component, or Feature Panel entry. Hover for battery and connection details. With a separate icon, either mouse button opens plugin settings. With replacement, the original MacTools panel click behavior is preserved.

Replacement uses the [host's exclusive icon interface](menu-bar-icons.md), not direct access to its button. If another plugin already owns the primary icon, the mode remains unchanged and an inline error names that plugin; pending updates instead explain that a restart is needed to access its settings. Switching back or uninstalling restores the original MacTools artwork, including custom or animated icons. A failed uninstall preserves the previous mode. General icon settings explain when edits apply while replacement is active. The host keeps its click behavior, saved position, and automation badge. Separate mode has its own status item and saved position.

- The battery arc is green while charging, red below 20% while not charging, and monochrome otherwise. Charging takes precedence over low battery.
- A lightning bolt means active charging; a plug means external power with charging paused or complete.
- Four dots represent Wi-Fi signal strength. Missing readings remain unavailable, rather than appearing as a full signal.
- The center represents the active network connection, including Wi-Fi and Ethernet. Connection state does not establish that internet access works.
- Macs without an internal battery show a dashed neutral arc.

Both display modes use the same inset vector artwork, with a visible height of approximately 17–18 points inside the 24-point canvas. A fixed optical center keeps the icon stable across power states, and AppKit renders at the display's native scale on macOS 14 or later. The icon follows the menu bar's effective appearance, including wallpaper and display changes. Tooltip and accessibility copy follow the host's selected language.

## Lifecycle and privacy

Battery and Wi-Fi reads run on a utility queue. Power-source notifications and network-path changes request updates; a tolerant 15-second timer refreshes Wi-Fi signal strength. Read requests coalesce, unchanged snapshots do not redraw the icon, and callbacks from a stopped monitoring generation are discarded.

Losing the host capability, disabling or uninstalling the plugin, and replacing the plugin during an update stop monitoring and remove its separate status item. The host restores its primary icon before teardown. Switching display mode shares the existing monitor without restarting it. Locking or sleeping pauses monitoring; interactive activity resumes it with a fresh snapshot. Settings and image getters never query hardware synchronously.

The plugin uses native IOKit, CoreWLAN, and Network APIs. It does not read SSIDs, request location access, test internet endpoints, collect history, or send telemetry. Placement is stored by the host; the plugin does not duplicate ownership in its preferences. Unknown and unavailable hardware states remain explicit.

## Development

Plugin implementation, localization, and adjacent tests live under `Plugins/DuoStatus`. Its `project.yml` declares only the required system frameworks. Generic primary-icon arbitration lives in Core and the optional public contracts live in PluginKit; the host does not contain Duo-specific rendering or settings.

```sh
make generate
make build-plugin PLUGIN=DuoStatus
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/DuoStatusPluginTests \
  -only-testing:MacToolsTests/DuoStatusIconTests \
  -only-testing:MacToolsTests/DuoSystemStatusReaderTests \
  -only-testing:MacToolsTests/DuoSystemStatusMonitorTests
make script-tests
```

Tests use synthetic readings, isolated notification centers, in-memory preferences, and fake menu-bar presenters. They cover hardware normalization, charging and appearance rendering, stale callback rejection, settings persistence, host activity, and resource cleanup without changing the developer's menu bar or querying real hardware.
