# MacTools Local Native Plugins

MacTools supports trusted local native plugins through a host-owned package store and a shared `MacToolsPluginKit.framework`.

This phase intentionally supports only trusted local plugins built by the same developer identity as the host app. The host validates the plugin bundle signature before loading code. Disabling or uninstalling a plugin immediately removes its contributions from the UI and deletes package files when requested, while already-loaded native code is fully released after the app restarts.

For catalog-based installation, GitHub release distribution, and Debug `file://` development catalogs, see [plugin-catalog.md](plugin-catalog.md).

For a complete workspace-plugin example with a typed catalog, verified adapters, portable preferences, profiles, and composition of canonical actions from other providers, see [Mac Settings](mac-settings.md).

## Package Layout

Use a directory package with the `.mactoolsplugin` extension:

```text
Example.mactoolsplugin/
  plugin.json
  LICENSE                    # Required when the package is distributed independently
  THIRD_PARTY_NOTICES.txt    # Present only when third-party notices apply
  Example.bundle/
    Contents/
      Info.plist
      MacOS/Example
      Resources/
```

`plugin.json` is read before loading executable code:

Set `minHostVersion` to the first host that exports every PluginKit API used by the package. In PluginKit v5, `PluginDashboardPresenting`, `PluginComponentDetailPresenting`, and `PluginComponentDetailContent` require MacTools 1.2.1. System Status declares this floor so 1.2.0 hosts cannot install a package with unavailable symbols.

```json
{
  "id": "com.example.mactools.demo",
  "displayName": "Demo",
  "summary": "示例插件",
  "localizedMetadata": {
    "zh-Hans": {
      "displayName": "示例",
      "summary": "示例插件"
    },
    "en": {
      "displayName": "Demo",
      "summary": "Demo plugin"
    }
  },
  "version": "1.0.0",
  "minHostVersion": "1.2.0",
  "pluginKitVersion": 5,
  "bundleRelativePath": "Example.bundle",
  "factoryClass": "Example.ExamplePluginFactory",
  "capabilities": {
    "primaryPanel": true,
    "componentPanel": false,
    "settings": "form"
  },
  "permissions": [],
  "category": "productivity"
}
```

`displayName` and `summary` are fallback marketplace metadata. Add `localizedMetadata` for every user-facing marketplace language the plugin supports. The host chooses the best match from the user's language preferences before the plugin bundle is loaded, but it does not own plugin translations.

`category` is optional and is used by the marketplace and "已安装" list to group plugins. Supported values: `display`, `audio`, `system`, `storage`, `productivity`, `monitoring`. Unknown or omitted values fall back to "其他".

The plugin bundle must expose a factory that conforms to `MacToolsPluginBundleFactory`. The factory returns a `PluginProvider`, and the provider returns exactly one `MacToolsPlugin` instance for the package.

Source repositories can keep implementation and tests beside each plugin:

```text
Plugins/Example/
  plugin.json
  Sources/              # Plugin implementation and feature code
  Bundle/               # Thin bundle entrypoint that anchors the factory
  Tests/                # Optional XCTest files
  project.yml           # Optional build overrides for non-default plugins
  Resources/            # Optional plugin resources
```

The runtime payload contains the projected `plugin.json` and the built `.bundle`. Bundle resources must therefore be copied into the built `.bundle` by the generated Xcode target. In this repository, `Plugins/<PluginName>/Resources` is automatically added to the generated bundle target, so plugin-owned `.xcstrings`, images, JSON files, and other runtime resources should live there. Official release packaging also copies the repository `LICENSE` into every independently distributed ZIP and generates a product-specific `THIRD_PARTY_NOTICES.txt` when required. These legal files are generated from central sources and are not maintained inside each plugin source directory. `Tests/` is included only by the host unit-test target during development and is never packaged into the app or plugin distribution.

In this repository, plugin Xcode targets are generated before XcodeGen runs. The generator scans `Plugins/*/plugin.json` and applies a shared target template for `Sources/`, `Bundle/`, `Tests/`, plugin schemes, and the host test target. Most plugins do not need any root project changes. Add `Plugins/<PluginName>/project.yml` only for plugin-local build differences such as `OTHER_LDFLAGS`, `SWIFT_INCLUDE_PATHS`, extra bundle resources, helper/tool targets, or additional target dependencies. A helper/tool target can declare `bundleResourcePath` to have the generated bundle target copy its built executable into `Contents/Resources/<bundleResourcePath>/`.

The manifest ID is the stable identity of the package. It must match the runtime `PluginMetadata.id`, and a package must return exactly one plugin instance. Use lower-case, readable IDs such as `display-brightness` unless there is a strong reason to use a reverse-DNS identifier. The ID `marketplace` is reserved for the host-owned URL route and is not a valid plugin ID.

The same source manifest may add optional product metadata for pre-install discovery, requirements, privacy, actions, setup, and plugin relationships. Follow [`plugin-manifest.schema.json`](plugin-manifest.schema.json); do not create a second marketplace metadata file. Declare localized product copy under the source-only `productStrings` table. Each entry either reuses `@displayName` or `@summary`, imports an existing `Resources/Localizable.xcstrings` key with `@localizable.<key>`, uses a standard localized toggle or enabled-state label with `@standardAction.<key>`, renders declared requirements with `@standardSetup.requirements.title` or `@standardSetup.requirements.description`, or supplies all 11 supported locale values; localized product fields uniformly reference `@productStrings.<key>`. Packaging and catalog generation expand the references and remove the source table before distribution. Keep screenshots under `MarketplaceAssets/`, and describe dynamic machine-local action entries with templates instead of enumerating local values. The catalog generator validates localization, identifiers, permission and surface values, references, domains, assets, and action completeness before projection.

When a plugin uses a private Apple framework, it must load that framework dynamically at runtime and validate every required class and selector before use. Do not add a static framework link: unsupported systems must present a clear plugin error instead of crashing.

## Development Steps

To add a plugin, create `Plugins/<PluginName>/plugin.json`, `Sources/`, and `Bundle/`. Add `Tests/` when the behavior is testable. Most plugins can then run directly with:

```bash
make run
```

Finder Sync, Share, Quick Look, and other macOS app extensions are host-level targets. A plugin may expose settings or status for that feature, but the extension target itself must be embedded by the main app through `project.yml`; it cannot be installed into Finder by a dynamic `.mactoolsplugin` bundle at runtime.

In Debug development, `make run` builds the main `MacTools` scheme, synchronizes the freshly built plugin bundles from `build/DerivedData/Build/Products/Debug` into `build/LocalPlugins/Packages`, generates `build/LocalPlugins/catalog.dev.json`, and updates `~/Library/Application Support/MacTools Dev/Plugins/Installed`. It then stages and verifies a rollback-safe replacement of `~/Applications/MacTools Dev.app` before launching that stable path. The installer refuses a replacement whose designated code-signing requirement differs from the previously installed app, preserving macOS permission grants across rebuilds. When that stable Debug app exists, Derived Data copies do not start the exclusive trackpad listener, and the generated XCTest action explicitly disables it for the test host. This prevents an old build or a lingering hosted test app from taking gesture input after the installed app restarts.

A full Debug sync mirrors the current checkout: packages missing from its local catalog are moved from `Installed` to the sibling `Quarantined` directory so packages left by another worktree cannot appear as incompatible. A filtered sync such as `make sync-debug-plugins PLUGIN=calendar` preserves unrelated installed packages.

Debug package copies normalize `minHostVersion` to the locally built app version because the host and plugin bundles come from the same checkout. Release packages preserve each source manifest's declared minimum host version.

If the plugin needs extra frameworks, private include paths, bundle resources, helper/tool targets, or target dependencies, add only those differences in `Plugins/<PluginName>/project.yml`. If the plugin package contains an extra executable inside the bundle resources, declare it in `plugin.json.package.signPaths` so release packaging signs it before signing the bundle.

Plugin UI copy should be localized by the plugin itself. Put plugin string catalogs under `Plugins/<PluginName>/Resources`, then look them up from the plugin bundle, for example:

```swift
private enum DemoL10n {
    static let strings = PluginLocalization(bundle: Bundle(for: DemoPluginFactory.self))

    static var title: String {
        strings.string("metadata.title", defaultValue: "示例")
    }
}
```

To resynchronize already-built Debug plugin bundles without launching the app:

```bash
make sync-debug-plugins
```

To test the standalone plugin package build path, build its package and Debug catalog explicitly:

```bash
make build-plugin PLUGIN=<plugin directory or id>
make run
```

To update an existing plugin, change its code/resources/tests beside the plugin and run the focused build or tests before opening a PR. Do not bump `plugin.json.version` in a normal feature PR. The standard `make release` flow detects package-relevant changes, automatically bumps affected manifests, and records those updates in the plugin release commit.

When a change touches `Sources/MacToolsPluginKit/`, it is package-relevant for every plugin. `make release` automatically selects and bumps every affected manifest so all plugin packages are rebuilt against the same PluginKit build. A manual version bump is needed only when bypassing `make release` and using the lower-level release workflow directly.

## Settings UI

Plugin settings are hosted by MacTools. PluginKit 5 exposes one `settingsPage` entry point with two explicit layouts:

- `PluginSettingsPage.form` is the default. Describe standard controls with `PluginSettingsSection`, `PluginSettingsRow`, and `PluginSettingsControl`; the host renders the native grouped form, search entries, validation, permissions, and shortcuts.
- Reserve segmented pickers for a few short labels; use `.menu` when options are longer or localization can make the row overflow. Declarative sliders should provide `valueFormat` for a live host-rendered readout. Custom settings use `PluginSettingsSlider` to keep stepped values without drawing dense tick marks.
- A form may contain a custom section for a complex list, chart, drag and drop editor, or manager while retaining the host-owned page shell and surrounding native sections.
- `PluginSettingsPage.workspace` is reserved for a task-oriented full settings surface such as a cleanup browser or configuration editor. Declare `scrolling: .host` for a simple long page and `.selfManaged` for split views, lists, or editors. The host still owns navigation, header, permissions, shortcuts, background, and lifetime.
- Use `.onVisibilityChange` for work that belongs to the whole settings page, such as starting observation or stopping a test session. Do not attach page lifetime work to custom section `onAppear`/`onDisappear`; grouped Form sections are lazy and may be recycled while the page is still visible.
- Use `permissionRequirements` for system permission rows and `shortcutDefinitions` for shortcut rows. A form places a shortcut group with `PluginSettingsSection.shortcutGroup`; a custom section that renders a group itself declares `embeddedShortcutGroupIDs`.

The manifest must declare the matching `capabilities.settings` value: `none`, `form`, or `workspace`. The host does not read an undeclared page and rejects a runtime layout that differs from the manifest. This capability is an ABI contract, not a styling preference.

## Pointer-intercepting plugins

Plugins that use a `CGEvent` tap must declare `accessibility` in `plugin.json.permissions` and expose the matching `PluginPermissionRequirement`. Start the tap only after authorization, stop and invalidate it during deactivation, and re-enable it after `.tapDisabledByTimeout` or `.tapDisabledByUserInput`. Keep callback work bounded; never perform I/O, scanning, or blocking operations there.

Settings changes use typed `PluginSettingsAction` values (`setBoolean`, `setSelection`, `setNumber`, `setText`, and `invoke`) instead of string-only callbacks. Text and numeric controls distinguish `.changed` from `.committed`, allowing live updates without rebuilding the entire settings hierarchy for every keystroke or slider tick.

Custom sections and workspaces provide only plugin-specific content. The settings window title, plugin icon, description, permission cards, shortcut cards, scrolling shell, and system background are derived by the host; do not repeat a page title inside custom content. Form sections must not draw their own outer card or section header: use `presentation: .standard` for normal custom content, or `.edgeToEdge` for an AppKit table or an internally padded row collection. Add/Refresh-style actions belong in `.headerAccessory`.

All custom settings views should use `MacToolsPluginKit.PluginSettingsTheme` for typography, spacing, radii, colors, and shared card backgrounds. This keeps the dependency direction clean: the host app and plugins both depend on `MacToolsPluginKit`, while plugins never depend on `Sources/App/SettingsStyle.swift`.

Recommended mapping:

- Page-level text: `PluginSettingsTheme.Typography.pageTitle` and `pageDescription`.
- Section labels: `Label` with an SF Symbol, `sectionTitle`, and `.foregroundStyle(.secondary)`.
- Row text: `rowTitle` or `emphasizedRowTitle`; supporting text uses `rowDescription`; status pills use `statusBadge`.
- Fixed-width numeric or path-like values may use `monospacedValue` or a local monospaced font when the content requires it.
- Layout: use `Spacing.section`, `sectionHeaderContent`, `cardContent`, `rowHorizontal`, `rowVertical`, `interactiveRowVertical`, and `rowContentControl`.
- Containers: grouped Form supplies ordinary settings cards. Use `.pluginSettingsCardBackground(.standard)` only inside workspaces, and `.recessed` for inset fields or log panes.
- Ordinary settings cards should be separated by background color, spacing, and rounded corners rather than borders. Reserve strokes for focused inputs, keycaps, badges, or other control-specific states.

Avoid copying a plugin-local settings style enum. If a token is missing, add it to `PluginSettingsTheme` instead of hard-coding the same value in multiple plugins.

### Unified Search

MacTools automatically indexes visible declarative row titles, descriptions, keywords and picker options, plus permission and shortcut rows. Current text-field and secure-field values are never indexed. Custom sections and workspaces can expose individual destinations by conforming to `PluginSettingsSearchProviding`; apply `pluginSettingsSearchAnchor(pluginID:entryID:)` to the matching control so selecting a result scrolls to, highlights, and exposes accessibility focus.

Commands are never inferred from panel buttons. A plugin must explicitly conform to `PluginCommandProviding` and publish only actions that are safe and useful in the global palette. Commands that need an extra user decision should provide confirmation metadata. Destructive actions should remain in their contextual plugin UI unless their complete safety flow can be represented by that confirmation.

New executable capabilities should use `PluginActionProviding` rather than adding new legacy commands or shortcut-owned callbacks. Publish stable `ActionKey` values, versioned parameter schemas, availability snapshots, risk/confirmation policy, external-invocation policy, execution capabilities, and bounded timeouts. If discovery surfaces should name system permissions before execution, also implement `PluginActionPermissionProviding` and map each action to IDs declared by `permissionRequirements`.

Host-owned system integrations may additionally consult the optional `PluginActionExposureProviding` contract. `.excluded` is a provider veto; `.automatic` delegates to the host's conservative eligibility checks and does not bypass risk, availability, permission, parameter, or foreground requirements. Unknown surfaces and provider failures must fail closed, and exposure is revalidated at execution time. Keep `externalInvocationPolicy` separate because it governs Run Links rather than general system discovery.

If an action executes mutable provider-owned content that is not represented by its `ActionDefinition` or catalog entry, also implement `PluginActionExecutionRevisionProviding`. Advance the revision after every successful persisted mutation. The host snapshots and revalidates it around confirmation so a user never approves one payload and executes another.

Treat action execution capabilities as explicit safety contracts. Add `.automatic` only when the action can run unattended without confirmation or foreground UI; `.background` alone does not permit automatic rules. Choose an `ActionConcurrencyPolicy` for overlap-sensitive actions (`.rejectWhileRunning` is the safe default, `.serialize` queues, and `.allowConcurrent` is opt-in). `beginAction` must validate and return an `ActionExecutionHandle` promptly; move substantive work into the handle operation. Every action has a host-enforced deadline, while `.cancellable` additionally authorizes the host to invoke the provider cancellation callback.

Ordinary action shortcuts are owned by the host's `ShortcutAssignmentService`. A plugin may declare or migrate a default binding, but it must not persist or register a second binding for the same action. Workflows, Run Links, and Action Grid also retain `ActionReference` values and invoke through the host executor. See [Actions, Automation, Run Links, and Action Grid](../actions-automation.md) for the ownership and verification contract.

The current migration coverage, intentional exclusions, and design-first backlog are tracked in [Canonical action provider coverage](action-provider-coverage.md). Consult that inventory before adding a new plugin-only command or shortcut so reusable operations remain available consistently across shortcuts, gestures, Action Grid, Automation, Unified Search, and eligible Run Links.

Action Grid is the reference implementation for an optional action surface. Its package can be built independently with:

```bash
make build-plugin PLUGIN=ActionGrid
```

## Install Location

Installed plugins are copied into:

```text
~/Library/Application Support/MacTools/Plugins/
  Installed/
  Staging/
  Data/
  Caches/
  Temporary/
```

Debug builds use a separate application identity and storage root:

```text
~/Library/Application Support/MacTools Dev/Plugins/
```

Install and update are staged before moving into `Installed`. Per-plugin runtime context includes scoped `UserDefaults` storage plus support, cache, temporary, and bundle resource locations.

## Security Model

- Only local package directories ending in `.mactoolsplugin` are accepted.
- The manifest ID, versions, and bundle relative path are validated before loading code.
- Host version and plugin kit version are checked before loading code.
- Installed packages built for an older PluginKit are kept on disk but marked incompatible and are never passed to the native bundle loader.
- Public value types within one PluginKit version must preserve their stored binary layout. CI compiles the frozen v5 `PluginShortcutRecorder` client declaration and links that client against the current framework so source-only tests cannot hide an incompatible in-place layout change.
- The plugin bundle signature is validated before loading code.
- When the host has a Team ID, the plugin bundle must have the same Team ID.
- Untrusted third-party native plugins should use a future isolated process or XPC model instead of in-process bundle loading.

## Lifecycle

Plugins can implement:

```swift
func activate(context: PluginRuntimeContext)
func deactivate(reason: PluginDeactivationReason)
```

`deactivate` is called before updating, uninstalling, and host shutdown. It can also be called when the host isolates a plugin after a runtime failure or when an installed package is no longer loadable. Plugins should cancel tasks, timers, observers, event taps, windows, and other retained system resources there.

Native bundle code is treated as loaded for the lifetime of the current app process. If a loaded plugin is updated or uninstalled, its contributions are removed from MacTools immediately and `deactivate` is called, but the executable code is considered fully released only after the app restarts. Updating a loaded plugin replaces the package files on disk and activates the new code on the next launch.
