# Duo Status

Duo Status (`duo-status`) is a PluginKit v6 plugin for MacTools 1.3.1 or later. It displays a separate 24-point menu-bar icon for the Mac's battery, Wi-Fi signal, and network connection. The implementation is adapted from the artwork and monitoring in [PR #434](https://github.com/ggbond268/MacTools/pull/434).

## Use

Install the plugin from the Marketplace. Its icon appears by default; **Duo Status > Menu Bar > Show Duo Icon** controls visibility. Hover for battery and connection details. Left-click or right-click opens the plugin's settings through the host settings router. There is no Dashboard component or Feature Panel entry.

The MacTools main icon, its customization preferences, click behavior, and automation badge remain owned by the host. Duo Status has its own status item and saved position and never replaces the main icon.

- The battery arc is green while charging, red below 20% while not charging, and monochrome otherwise. Charging takes precedence over low battery.
- A lightning bolt means active charging; a plug means external power with charging paused or complete.
- Four dots represent Wi-Fi signal strength. Missing readings remain unavailable, rather than appearing as a full signal.
- The center represents the active network connection, including Wi-Fi and Ethernet. Connection state does not establish that internet access works.
- Macs without an internal battery show a dashed neutral arc.

The icon follows the menu bar's effective appearance, including wallpaper and display changes. Tooltip and accessibility copy follow the host's selected language.

## Lifecycle and privacy

Battery and Wi-Fi reads run on a utility queue. Power-source notifications and network-path changes request updates; a tolerant 15-second timer refreshes Wi-Fi signal strength. Read requests coalesce, unchanged snapshots do not redraw the icon, and callbacks from a stopped monitoring generation are discarded.

Hiding the icon, disabling or uninstalling the plugin, and replacing the plugin during an update stop monitoring and remove the status item. Locking or sleeping pauses monitoring; interactive activity resumes it with a fresh snapshot. Settings and image getters never query hardware synchronously.

The plugin uses native IOKit, CoreWLAN, and Network APIs. It does not read SSIDs, request location access, test internet endpoints, collect history, or send telemetry. Only icon visibility is stored, in plugin-scoped preferences. Unknown and unavailable hardware states remain explicit.

## Development

All implementation, localization, and tests live under `Plugins/DuoStatus`. Its `project.yml` declares only the required system frameworks. No host UI or PluginKit API extension is required.

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
