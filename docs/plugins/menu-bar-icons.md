# Plugin menu-bar icons

Host 1.3.1 adds optional PluginKit v6 contracts for plugin-provided primary menu-bar artwork. The host keeps its existing status item, saved position, panel anchor, left/right click routing, accessibility, and automation badge. It does not add a host-side source picker. Plugins expose placement in their own settings.

## Contracts

- `PluginMenuBarIconProviding` declares stable `PluginMenuBarIconDescriptor` IDs and provides `menuBarIcon(for:context:)`. A render call reads an existing snapshot and must not query hardware, disk, or networks. Return a valid image in the requested point size, template status, localized tooltip and accessibility copy, and a revision that changes with the presentation. Never mutate published images.
- `PluginMenuBarIconRenderContext` supplies point size, display scale, and the actual menu bar appearance, independently of the app's selected theme. Vector images can use AppKit's drawing resolution. Keep any provider-side cache bounded.
- `PluginMenuBarIconHostContextConsuming` receives a revocable `PluginMenuBarIconHostContext`. It is scoped to that plugin and registration generation; requests take only a registered `iconID`, never a caller-supplied plugin ID.
- `requestPlacement(_:for:)` requests `.standalone` or `.primary` and returns a typed `Result`. A rejected request leaves the placement and preferences unchanged. Render the current selection from `placement(for:)`, not an optimistic local Boolean.
- `menuBarIconPlacementDidChange()` reports low-frequency ownership changes. Read `primaryIconOwner` for contextual feedback. When its `requiresRestart` flag is set, direct users to restart before changing the owner's settings. Do not retry acquisition automatically when another owner releases the slot.
- `onMenuBarIconChange(iconID)` invalidates only primary-icon presentation. Do not send high-frequency icon ticks through the plugin's general `onStateChange` callback.

The Core coordinator serializes ownership changes on MainActor. Only one `(pluginID, iconID)` can own the primary slot. Repeating the current claim succeeds without side effects; competitors receive `.occupied(owner:)`. Invalid images and expired or unregistered capabilities are rejected. There is no forced takeover. Settings should retain the previous segment and show a localized inline error naming the owner.

## Lifecycle and recovery

The host is the sole authority for placement persistence; plugins must not store a second copy. The selection is local to the installation and is not exported as portable plugin preferences. Original default, imported, and gallery icon settings remain untouched while a plugin supplies artwork.

At startup the saved owner is reserved until dynamic discovery finishes, so load order cannot steal the slot. The original icon remains visible while loading. A missing or failed provider releases the reservation. Native plugin updates that require restart keep the reservation and show the original icon until the new instance becomes available. An explicit uninstall clears even a pending, unloaded owner.

The dynamic plugin manager revokes host capabilities before deactivation and package removal. The coordinator removes the registration, restores the original primary artwork synchronously, and then clears the plugin context. Old closures cannot reacquire or release a replacement instance's slot. Shutdown preserves the saved selection; disable and isolation clear it. Uninstall preserves the selection until the existing discovery pass confirms removal, so a failed removal can reload the provider in its previous mode. A transient unreadable battery or network is business state, not a reason to release ownership.

General icon settings show a read-only ownership description, not a source picker. While a plugin is active, edits configure the icon used after replacement is turned off. While its update awaits restart, that configured icon is shown temporarily. Ownership metadata is observable independently of frame notifications, so sampling never refreshes the settings view.

Providers should wait for host-context injection before creating independent status items, preventing a duplicate during startup restoration. After a successful switch, the host applies primary artwork before notifying the provider to remove its independent item. Loss of the context must stop presentation and sampling, not create a fallback independent item during teardown. Sleep pauses sampling without releasing ownership.

## Performance

Only the selected provider's notifications reach the App renderer. Bursts are coalesced into one latest-state update per 150 ms window. The coordinator caches one rendered snapshot for the current source generation and render context; the App renderer skips unchanged revision/context combinations. There is no host polling timer or whole-panel rebuild on an icon tick. Provider-side monitors should be shared across independent and primary placement, not restarted for a placement-only change.

The host stops fallback icon animation while plugin artwork is selected and resumes it on restoration. It copies provider images before applying host properties and decorations. Arbitrary plugin views, click handlers, status buttons, and animation loops are not part of this contract. Native plugins still share the host process; the capability boundary is not process-level crash isolation.

## Validation

Run focused `PluginMenuBarIconCoordinatorTests`, `DuoStatusPluginTests`, `DynamicPluginManagerTests`, `MenuBarStatusItemControllerTests`, and `MenuBarIconSettingsTests`. Include competing claims, rejected settings changes, startup reservations, missing owners, updates, stale callbacks, teardown ordering, appearance caches, original-icon restoration, and notification coalescing. Run `make script-tests`, the PluginKit v6 binary compatibility fixture, and `make ci` before publishing cross-module changes. New API symbols must be recorded in the minimum-host inventory and adopting plugins must require host 1.3.1 or later.
