# Duo Status

Duo Status (`duo-status`) is a PluginKit v7 plugin for MacTools 1.3.1 or later. It displays a 24-point menu-bar icon for the Mac's battery, Wi-Fi signal, network connection, and optionally output volume. The implementation is adapted from the artwork and monitoring in [PR #434](https://github.com/ggbond268/MacTools/pull/434).

Parts of the icon rendering and the network-state classification are adapted from the [Status Trio](https://github.com/lingyired/status-trio) project by lingyired, licensed under the [Apache License 2.0](../../Sources/Resources/ThirdPartyNotices/status-trio-LICENSE.txt). Only the combined menu-bar icon is adapted; the upstream popover, Dock presence, and other surfaces are not part of this plugin.

Hiding the system battery or Wi-Fi menu-bar icons is **not** part of this plugin. Use the [Menu Bar Hidden](menu-bar-hidden.md) plugin to manage which system icons appear in the menu bar.

## Use

Install the plugin from the Marketplace. **Duo Status > Menu Bar > Display Mode** offers **Separate Icon** (default) and **Replace App Icon**. There is no additional visibility switch, Dashboard component, or Feature Panel entry. Hover for battery, Wi-Fi, connection, and volume details. With a separate icon, either mouse button opens plugin settings. With replacement, the original MacTools panel click behavior is preserved.

Replacement uses the [host's exclusive icon interface](menu-bar-icons.md), not direct access to its button. If another plugin already owns the primary icon, the mode remains unchanged and an inline error names that plugin; pending updates instead explain that a restart is needed to access its settings. Switching back or uninstalling restores the original MacTools artwork, including custom or animated icons. A failed uninstall preserves the previous mode. General icon settings explain when edits apply while replacement is active. The host keeps its click behavior, saved position, and automation badge. Separate mode has its own status item and saved position.

- The battery ring uses status colors: red below the low-battery threshold, yellow in Low Power Mode, green while charging, and monochrome otherwise, including on power without charging. A critically low level takes precedence, so a Mac charging at a very low level still shows the warning color. Status colors can be turned off entirely.
- A lightning bolt means active charging; a plug means external power with charging paused or complete. The charging indicator can be hidden.
- The battery percentage can be shown in the ring's top gap, so it sits beside the network glyph instead of replacing it. You can also keep the charging mark instead of the number while connected to power.
- The center represents the active network connection, including Wi-Fi and Ethernet. Connection state does not establish that internet access works.
- Connected without internet access, personal hotspot, temporary networks, and Internet Sharing each have a dedicated glyph. Each one is off by default and falls back to the plain Wi-Fi fan, while the tooltip always names the precise state.
- Four dots at the bottom represent Wi-Fi signal strength, or output volume if you switch them. Volume can instead use a continuous bar along the ring's bottom gap. Missing readings remain unavailable, rather than appearing as a full signal; muted or silent output shows no lit dots and an empty bar. The tooltip says which quantity the bottom indicator represents.
- When the default output device uses Bluetooth, a Bluetooth glyph can replace the network glyph. Network problems can still take priority over it.
- Macs without an internal battery show a neutral full ring.

Both display modes use the same inset vector artwork inside the 24-point canvas, in a small, medium, or large size. A fixed optical center keeps the icon stable across power states, and AppKit renders at the display's native scale on macOS 14 or later. The icon follows the menu bar's effective appearance, including wallpaper and display changes. Tooltip and accessibility copy follow the host's selected language.

## Settings

All settings apply immediately to both display modes. Every option beyond the icon size ships off by default, so an existing menu bar looks unchanged after an update.

- **Appearance**: pick a small, medium, or large icon size.
- **Battery**: show the percentage in the ring's top gap, optionally only while on battery; show the charging indicator; use status colors; set the low-battery threshold used for the warning color.
- **Network**: separately distinguish connected-without-internet, personal hotspot, temporary networks, and Internet Sharing with their own glyphs.
- **Volume and audio**: choose whether the bottom indicator shows Wi-Fi signal or output volume, and draw volume as dots or a bar; let a Bluetooth output device replace the network glyph, and choose whether network errors still win.

## Lifecycle and privacy

Battery, Wi-Fi, and network-path reads run on a utility queue. Power-source notifications and network-path changes request updates; a tolerant 15-second timer refreshes Wi-Fi signal strength. Read requests coalesce, unchanged snapshots do not redraw the icon, and callbacks from a stopped monitoring generation are discarded.

Audio monitoring is opt-in. CoreAudio listeners for the default output device and its volume are installed only while an enabled option needs them, namely volume dots or the Bluetooth glyph, and are torn down again when those options are turned off.

Losing the host capability, disabling or uninstalling the plugin, and replacing the plugin during an update stop monitoring and remove its separate status item. The host restores its primary icon before teardown. Switching display mode shares the existing monitor without restarting it. Locking or sleeping pauses monitoring; interactive activity resumes it with a fresh snapshot. Settings and image getters never query hardware synchronously.

The plugin uses native IOKit, CoreWLAN, Network, SystemConfiguration, and CoreAudio APIs. It does not read SSIDs, request location access, test internet endpoints, collect history, use the network, or send telemetry. It persists only its own icon settings; placement is stored by the host and is not duplicated in plugin preferences. Unknown and unavailable hardware states remain explicit. The plugin never changes which system icons macOS shows in the menu bar.

## Development

Plugin implementation, localization, and adjacent tests live under `Plugins/DuoStatus`. Its `project.yml` declares only the required system frameworks. Generic primary-icon arbitration lives in Core and the optional public contracts live in PluginKit; the host does not contain Duo-specific rendering or settings. Source files adapted from upstream carry an attribution comment, and the retained license text is listed in `Sources/Resources/ThirdPartyNotices/manifest.json`.

```sh
make generate
make build-plugin PLUGIN=DuoStatus
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/DuoStatusPluginTests \
  -only-testing:MacToolsTests/DuoStatusIconTests \
  -only-testing:MacToolsTests/DuoStatusIconMappingsTests \
  -only-testing:MacToolsTests/DuoSystemStatusReaderTests \
  -only-testing:MacToolsTests/DuoSystemStatusMonitorTests \
  -only-testing:MacToolsTests/DuoWiFiClassifierTests
make script-tests
```

Tests use synthetic readings, isolated notification centers, in-memory preferences, and fake menu-bar presenters. They cover hardware normalization, option-driven rendering, network-state classification, audio-scope activation, stale callback rejection, settings persistence, host activity, and resource cleanup without changing the developer's menu bar or querying real hardware.
