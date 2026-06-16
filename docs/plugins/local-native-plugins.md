# MacTools Local Native Plugins

MacTools supports trusted local native plugins through a host-owned package store and a shared `MacToolsPluginKit.framework`.

This phase intentionally supports only trusted local plugins built by the same developer identity as the host app. The host validates the plugin bundle signature before loading code. Disabling or uninstalling a plugin immediately removes its contributions from the UI and deletes package files when requested, while already-loaded native code is fully released after the app restarts.

Locally installed packages that carry `com.apple.quarantine` (typically zips downloaded with a browser — `ditto` propagates the attribute into the extracted bundle) have the attribute stripped during install, strictly after trust validation succeeds; a package that fails validation keeps its quarantine and the install fails. If stripping itself fails, the install reports a clear error instead of leaving a package that a hardened (Release) host would later refuse to `dlopen` with an opaque Gatekeeper/AMFI error. Catalog downloads are unaffected (`URLSession` downloads carry no quarantine).

For catalog-based installation, GitHub release distribution, and Debug `file://` development catalogs, see [plugin-catalog.md](plugin-catalog.md).

## Package Layout

Use a directory package with the `.mactoolsplugin` extension:

```text
Example.mactoolsplugin/
  plugin.json
  Example.bundle/
    Contents/
      Info.plist
      MacOS/Example
      Resources/
```

`plugin.json` is read before loading executable code:

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
  "minHostVersion": "0.15.2",
  "pluginKitVersion": 2,
  "bundleRelativePath": "Example.bundle",
  "factoryClass": "Example.ExamplePluginFactory",
  "capabilities": {
    "primaryPanel": true,
    "componentPanel": false,
    "configuration": true
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

Only `plugin.json` and the built `.bundle` are copied into a `.mactoolsplugin` package. Bundle resources must therefore be copied into the built `.bundle` by the generated Xcode target. In this repository, `Plugins/<PluginName>/Resources` is automatically added to the generated bundle target, so plugin-owned `.xcstrings`, images, JSON files, and other runtime resources should live there. `Tests/` is included only by the host unit-test target during development and is never packaged into the app or plugin distribution.

In this repository, plugin Xcode targets are generated before XcodeGen runs. The generator scans `Plugins/*/plugin.json` and applies a shared target template for `Sources/`, `Bundle/`, `Tests/`, plugin schemes, and the host test target. Most plugins do not need any root project changes. Add `Plugins/<PluginName>/project.yml` only for plugin-local build differences such as `OTHER_LDFLAGS`, `SWIFT_INCLUDE_PATHS`, extra bundle resources, helper/tool targets, or additional target dependencies. A helper/tool target can declare `bundleResourcePath` to have the generated bundle target copy its built executable into `Contents/Resources/<bundleResourcePath>/`.

The manifest ID is the stable identity of the package. It must match the runtime `PluginMetadata.id`, and a package must return exactly one plugin instance. Use lower-case, readable IDs such as `display-brightness` unless there is a strong reason to use a reverse-DNS identifier.

## Development Steps

To add a plugin, create `Plugins/<PluginName>/plugin.json`, `Sources/`, and `Bundle/`. Add `Tests/` when the behavior is testable. Most plugins can then run directly with:

```bash
make run
```

In Debug development, `make run` builds the main `MacTools` scheme, then synchronizes the freshly built plugin bundles from `build/DerivedData/Build/Products/Debug` into `build/LocalPlugins/Packages`, generates `build/LocalPlugins/catalog.dev.json`, and updates `~/Library/Application Support/MacTools Dev/Plugins/Installed`. This keeps the local marketplace and installed plugins on the latest source code without running a separate plugin build.

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

To update an existing plugin, change its code/resources/tests beside the plugin. If the update should be released through the plugin catalog, bump only that plugin's `plugin.json.version`, then run the focused build or tests before opening a PR.

## Settings UI

Plugin settings are hosted by MacTools. Prefer the descriptive surfaces first:

- Use `settingsSections` for simple status/action cards.
- Use `permissionRequirements` for system permission rows.
- Use `shortcutDefinitions` for global shortcut rows.
- Use `PluginConfiguration` only when the plugin needs a custom manager, list, editor, drag-and-drop surface, chart, or other interaction that cannot be expressed by the descriptive models.

Custom configuration views must provide only the plugin-specific content. The settings window header, plugin icon, plugin description, permission cards, and shortcut cards are derived by the host; do not repeat a full page title inside the custom view.

All custom settings views should use `MacToolsPluginKit.PluginSettingsTheme` for typography, spacing, radii, colors, and shared card backgrounds. This keeps the dependency direction clean: the host app and plugins both depend on `MacToolsPluginKit`, while plugins never depend on `Sources/App/SettingsStyle.swift`.

Recommended mapping:

- Page-level text: `PluginSettingsTheme.Typography.pageTitle` and `pageDescription`.
- Section labels: `Label` with an SF Symbol, `sectionTitle`, and `.foregroundStyle(.secondary)`.
- Row text: `rowTitle` or `emphasizedRowTitle`; supporting text uses `rowDescription`; status pills use `statusBadge`.
- Fixed-width numeric or path-like values may use `monospacedValue` or a local monospaced font when the content requires it.
- Layout: use `Spacing.section`, `sectionHeaderContent`, `cardContent`, `rowHorizontal`, `rowVertical`, `interactiveRowVertical`, and `rowContentControl`.
- Containers: use `.pluginSettingsCardBackground(.host)` for host-style cards, `.pluginSettingsCardBackground(.plugin)` for native plugin lists, and `.pluginSettingsCardBackground(.recessed)` for inset fields/log panes.
- Ordinary settings cards should be separated by background color, spacing, and rounded corners rather than borders. Reserve strokes for focused inputs, keycaps, badges, or other control-specific states.

Avoid copying a plugin-local settings style enum. If a token is missing, add it to `PluginSettingsTheme` instead of hard-coding the same value in multiple plugins.

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
- The plugin bundle signature is validated before loading code.
- When the host has a Team ID, the plugin bundle must have the same Team ID.
- Untrusted third-party native plugins should use a future isolated process or XPC model instead of in-process bundle loading.

## Lifecycle

Plugins can implement:

```swift
func activate(context: PluginRuntimeContext)
func deactivate(reason: PluginDeactivationReason)
```

`deactivate` is called before disabling, updating, uninstalling, and host shutdown. Plugins should cancel tasks, timers, observers, event taps, windows, and other retained system resources there.

Native bundle code is treated as loaded for the lifetime of the current app process. If a loaded plugin is disabled, updated, or uninstalled, its contributions are removed from MacTools immediately and `deactivate` is called, but the executable code is considered fully released only after the app restarts. Updating a loaded plugin replaces the package files on disk and activates the new code on the next launch.
