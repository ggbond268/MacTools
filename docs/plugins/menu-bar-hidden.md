# Hide Menu Bar Icons

`Plugins/MenuBarHidden/` restores the `menu-bar-hidden` plugin for PluginKit v6 under `GPL-3.0-only`. It hides menu-bar items to the left of a divider and provides visible, hidden, and always-hidden layout areas. The component panel can show captured hidden icons and forward clicks to their original menu-bar items.

The basic hiding switch works without Accessibility or Screen Recording permission. Dragging items and using captured icons require both permissions; the settings page explains missing grants. Icon captures remain in memory. The plugin stores its preferences and item layout locally and makes no network requests.

The existing `set-enabled` action remains available to host actions and automation. Its Boolean parameter is explicit and idempotent, and does not require capture or input permissions. Existing plugin storage keys and identifiers are preserved.

## Build and Verification

Run `make generate`, then `make build-plugin PLUGIN=MenuBarHidden`. No root XcodeGen target changes are needed. Local packages and future signed releases use the repository's normal catalog and legal-notice generation.

Run focused tests with:

```sh
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/MenuBarHiddenPluginTests \
  -only-testing:MacToolsTests/MenuBarHiddenPolicyTests \
  -only-testing:MacToolsTests/MenuBarHiddenStoreTests \
  -only-testing:MacToolsTests/PluginRuntimeActionSnapshotTests
make script-tests
```

Manual checks require a graphical macOS session: enable and disable hiding, keep the MacTools icon reachable, move icons between all three sections, forward left and right clicks, revoke each permission, reconnect a display, switch Spaces, sleep and wake, relaunch, and uninstall the plugin. Verify that uninstall restores access to hidden icons. WindowServer enumeration and event targeting use private system interfaces, so successful compilation does not establish compatibility with every macOS release.

## Licensing

The restored implementation contains Thaw / Ice adaptations recorded in the [central third-party notice inventory](../../Sources/Resources/ThirdPartyNotices/manifest.json). The plugin ZIP must include the GPL `LICENSE` and generated notices containing both upstream license texts and copyright notices.

Existing signed production catalogs remain immutable until a normal, separately signed plugin release publishes the restored package.
