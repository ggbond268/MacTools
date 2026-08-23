# Agent Instructions for MacTools

## Instruction Scope
- This file is the canonical agent guide for this repository and applies to the entire repo.
- If a closer `AGENTS.md` appears in a subdirectory in the future, the closer file takes precedence.
- `CLAUDE.md` and `GEMINI.md` are compatibility entry points only; shared rules should be maintained here first.

## Language
- Code, code comments, and Markdown documentation added or modified by Codex must be written in English.
- User-facing app copy remains subject to the project’s localization guidelines.

## Project Overview
- MacTools is a native macOS menu-bar utility collection for frequent, lightweight, non-disruptive system tasks.
- The stack is Swift 6 with SwiftUI + AppKit, targeting macOS 14.0 or later.
- Features are organized as plugins. Current plugin source lives under `Plugins/<PluginName>/` and is integrated into the host through `MacToolsPluginKit`, dynamic plugin packages, and catalogs.
- User-facing copy is currently primarily Chinese. New copy should stay concise, clear, and close to native macOS phrasing.

## Key Directories
- `Sources/App/`: app entry point, menu-bar status item, panels, settings pages, and window routing.
- `Sources/Core/Plugins/`: plugin host, dynamic plugin loading, package installation, catalog validation, and display preferences.
- `Sources/Core/Shortcuts/`: global shortcut models, storage, and management.
- `Sources/Core/Permissions/`: system permission checks.
- `Sources/Core/Diagnostics/`: shared logging entry points.
- `Sources/Core/Updates/`: Sparkle update checks and About-page update state.
- `Sources/MacToolsPluginKit/`: plugin protocols, declarative UI models, shortcut models, and runtime context.
- `Plugins/<PluginName>/`: plugin manifest, source, bundle entry point, resources, and adjacent tests.
- `Tests/`: XCTest coverage for shared App/Core logic; plugin tests should prefer the corresponding plugin directory.
- `Configs/`: Xcode build settings and `Info.plist`.
- `docs/plugins/`: plugin package, catalog, local debugging, and release-process documentation.
- `docs/superpowers/`: larger product/interaction specs and implementation plans.
- `scripts/`: release, signing, notarization, and GitHub Release helper scripts.

## Build And Run
- Run `make setup` first to initialize `LocalConfig.xcconfig`, then fill in `DEVELOPMENT_TEAM` and `BUNDLE_IDENTIFIER_PREFIX`.
- `project.yml` is the root XcodeGen source. Plugin targets and schemes are generated locally into `Configs/GeneratedPlugins.yml` by `scripts/plugins/generate-plugin-project-config.rb`, which scans `Plugins/*/plugin.json`; that generated file is not committed.
- Generate the project with `make generate`. Do not run bare `xcodegen generate`, because it can miss the latest generated plugin configuration.
- Validate compilation with `make build`.
- Run locally with `make run`; it syncs the latest Debug plugin packages and generates the local development catalog.
- Sync only already-built Debug plugin packages and the local development catalog with `make sync-debug-plugins`.
- Build the local plugin packages and generate the Debug catalog with `make build-plugin`.
- Build one plugin with `make build-plugin PLUGIN=<plugin directory name or plugin ID>`.
- Run repository script tests with `make script-tests`; these checks are separate from XCTest and include PluginKit minimum-host compatibility validation.
- Run the full test suite with `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet`.
- Run one test class by appending `-only-testing:MacToolsTests/<TestClassName>` to the full test command.
- Run the CI-equivalent local validation with `make ci` before pushing cross-module or PluginKit changes.
- Use `./scripts/release-local.sh` only when a release is needed; confirm user intent before signing, notarizing, publishing, or tagging.

## Architecture Conventions
- Add new plugins under `Plugins/<PluginName>/` with at least `plugin.json`, `Sources/`, and `Bundle/`.
- Plugins implement `MacToolsPlugin`; menu-bar primary panels implement `PluginPrimaryPanel`, and component panels implement `PluginComponentPanel`.
- `plugin.json.id` must be stable, readable, and exactly match the runtime `PluginMetadata.id`; each `.mactoolsplugin` package must return exactly one plugin instance.
- `PluginHost` owns plugin ordering, visibility, shortcuts, permission cards, and derived display state. Individual plugins should not manipulate host UI directly.
- Plugin UI should be expressed through declarative models such as `PluginPanelState`, `PluginPanelDetail`, and `PluginPanelControl`. Except for `PluginComponentPanel.makeView`, avoid bypassing the existing panel framework with custom menu-bar UI.
- Plugin state and UI-related code should normally run on `@MainActor`. Long-running scans, filesystem work, or system calls should not block the main thread for extended periods. `primaryPanelState` and `componentPanelState` should read existing snapshots whenever possible, not synchronously scan hardware, filesystems, or networks from getters.
- `PluginHost` is responsible only for deriving common display state such as panel items, component items, and settings items. It caches component views and coalesces short-window state rebuilds; business-data snapshots, cache invalidation, and refresh timing remain the plugin or component's responsibility.
- After plugin state changes, call `onStateChange?()` so the host can rebuild derived state. If state can change due to external system events such as display hot-plugging, permission changes, filesystem changes, or calendar authorization changes, wire an explicit observer or refresh entry point with debounce/throttling. Do not depend on users expanding a panel, switching settings pages, or a full `refreshAll()` to get fresh data. Exception: high-frequency event sources such as input statistics or sampling counters may update only their own snapshots instead of calling `onStateChange?()` for every event; they must throttle UI notifications by visibility or a fixed time window and ensure `refresh()` or user panel opening can read the latest snapshot.
- External state changes with cross-plugin value should be abstracted into Core-layer protocols or observers first. For example, display-topology changes should use `DisplayConfigurationObserving` to notify the host, then refresh display-related plugins that implement `DisplayTopologyRefreshing`.
- Control IDs, plugin IDs, and shortcut IDs must be stable, readable, and preferably centralized in private constants within the feature.
- Ordinary new plugins do not need root `project.yml` changes. Keep `plugin.json.build.scheme` pointing to the bundle scheme; the generator creates the core target, bundle target, test dependencies, and plugin scheme. If a plugin needs extra frameworks, include paths, bundle resources, or target overrides, declare only the minimal delta in `Plugins/<PluginName>/project.yml`.

## Plugin Settings UI Guidelines
- Plugin settings pages use `PluginSettingsPage`. Page title, icon, description, permission cards, shortcut cards, search, validation, and other common regions are derived and rendered by `PluginHost`/`SettingsView`; custom content must not duplicate a full-page title.
- Prefer `PluginSettingsPage.form` with declarative sections and typed controls. Use a custom form section only for a complex region, and `PluginSettingsPage.workspace` for task-oriented lists, drag and drop, charts, editors, or dedicated managers that need the full content area.
- Settings theme constants must use `MacToolsPluginKit.PluginSettingsTheme`. Plugin targets must not depend on `Sources/App/SettingsStyle.swift` or copy private settings-style definitions. When the theme needs extension, add it to `PluginSettingsTheme` first so dependencies remain host App -> PluginKit and plugin -> PluginKit.
- Use `FanControlPresetManagerView` as the visual baseline for custom plugin settings typography, expressed through `PluginSettingsTheme.Typography`: `pageTitle` for page titles and `pageDescription` for page descriptions; section headers should use `Label` + SF Symbol + `sectionTitle` + `.foregroundStyle(.secondary)`; normal row titles should use `rowTitle`; emphasized row titles or table headers should use `emphasizedRowTitle`; descriptions, help text, and subtitles should use `rowDescription`; status badges should use `statusBadge`; fixed-width numeric readings should use `monospacedValue`. These tokens should map to Apple platform semantic fonts such as `.title2`, `.body`, and `.subheadline` whenever possible, instead of scattering raw font sizes across plugins.
- Host settings-page headers use `PluginSettingsTheme.Typography.pageTitle` + `pageDescription`. Custom plugin content starts at sections and should not introduce another page-level title.
- Base custom-configuration layout on Fan Control and prefer `PluginSettingsTheme.Spacing`: `section` for outer section spacing, `sectionHeaderContent` between a section header and content, `rowHorizontal` for card/list row horizontal padding, `rowVertical` for normal row vertical padding, `interactiveRowVertical` for rows containing editors or sliders, `rowTitleDescription` between row title and description, and `rowContentControl` between text and controls.
- Grouped Form owns ordinary settings cards; custom form sections must not draw another outer card or duplicate the host section header. Use `.standard` or `.edgeToEdge` section presentation as appropriate. In workspaces, prefer semantic `.pluginSettingsCardBackground(.standard)` and use `.recessed` only for inset fields or logs.
- Keep control layout stable: buttons should use system `.bordered`/`.borderedProminent` styles with `.controlSize(.small)`, switches should use `.toggleStyle(.switch)`, and sliders, pickers, text fields, and similar controls should have explicit minimum/ideal/maximum widths. Numeric text should have fixed width. Long titles and paths should use `lineLimit`, `fixedSize`, or text selection to avoid compression and layout jumps during window resizing.
- Copy should remain Chinese, short, and close to native macOS phrasing. Titles should name the object or setting, subtitles should explain effect or current state, and operation instructions should not become long prose blocks.

## Swift Code Style
- Follow the existing Swift style: small types, clear names, early returns, and minimal global state.
- Prefer Apple native frameworks. Explain the reason before adding a third-party dependency. Plugin-private system frameworks or include paths should be declared in the plugin's own `Plugins/<PluginName>/project.yml`.
- Add OSLog categories through `AppLog`; avoid bare `print` in app code.
- When interacting with AppKit, CoreGraphics, IOKit, EventKit, or other system APIs, preserve failure branches and fallback paths.
- Validate external inputs such as files, paths, permissions, display IDs, and shortcut bindings before use.
- Do not write local sensitive configuration such as signing certificates, notarization credentials, bundle prefixes, or development team IDs into the repository.

## Feature Safety Boundaries
- Disk cleanup: do not bypass `DiskCleanSafetyPolicy`, allowlists, sensitive-path protection, or pre-execution secondary validation. Expanding cleanup scope requires tests.
- Physical clean mode: preserve an exit path, Accessibility permission guidance, multi-display overlays, and safe exit after sleep or lock.
- Hide notch: do not destroy the user's original wallpaper; account for multi-display, Space switching, and wallpaper-change scenarios.
- Display brightness: keep the Apple-native, DDC/CI, and Gamma/Shade fallback chain; external-display failures must not crash.
- Display resolution: confirm the display is still connected and the target mode still exists before switching; errors should be converted into user-understandable state.
- Calendar: do not assume permission is granted; insufficient permission should show clear guidance instead of failing silently.
- Update release: keep Sparkle appcast, version, signing, and notarization changes small and careful; avoid committing local release artifacts.

## Testing Requirements
- Behavior changes should prefer adjacent XCTest additions or updates. Test files should use `<TypeName>Tests.swift`.
- Local and agent validation should default to the smallest relevant test method or class, such as `-only-testing:MacToolsTests/<TestClassName>` or `-only-testing:MacToolsTests/<TestClassName>/<testMethod>`. Do not run the full suite for narrow changes unless the scope justifies it.
- Plugin tests should prefer `Plugins/<PluginName>/Tests/`; shared Core/App tests should live under the corresponding `Tests/Core/` or `Tests/App/` path.
- Filesystem tests must use temporary directories or fake stores, and must never delete real user directories.
- Plugin interaction tests should cover `PluginPanelAction`, derived `PluginPanelState`, permission state, and error state.
- Changes that make a public PluginKit type newly consumable by plugins must run `make script-tests` so minimum-host inventory checks are not skipped.
- If tests cannot be run, explicitly state the reason and suggest the local verification command in the final response.

## Documentation And Resources
- User-visible feature changes should update `README.md`.
- User-visible app or plugin changes should add or update one concise English changelog fragment under `changes/unreleased/*.md`. Use `release: app` for app releases and `release: plugin` for plugin batch releases, plus `type: added`, `changed`, `fixed`, `security`, `removed`, `deprecated`, `maintenance`, or `summary`. If one change needs both release channels, write one app fragment for the host/app impact and one plugin fragment for the plugin-package impact; do not duplicate the same sentence. Keep entries user-facing, avoid duplicate wording, and do not describe implementation details. Pure refactors, tests, and local-only release mechanics do not need a fragment unless users or maintainers need to know about them.
- Plugin directories, manifests, catalogs, or release-flow changes should update `docs/plugins/` and `CONTRIBUTING.md`.
- Large product/interaction changes may add date-prefixed documents under `docs/superpowers/specs/` or `docs/superpowers/plans/`.
- Icons, asset catalogs, `LocalConfig.xcconfig`, and release env files are usually maintained by the user or generation flow; avoid unrelated changes.

## Agent Workflow
- Before modifying code, use `rg`/`rg --files` to quickly locate existing patterns and prefer adjacent implementations.
- Keep changes focused. Do not opportunistically refactor unrelated modules or overwrite existing user edits.
- After changing `project.yml`, run or recommend running `make generate`.
- Start verification from the smallest related test method or class. Consider full tests or `make build` only for cross-module changes, shared infrastructure changes, pre-release checks, or explicit user requests.
- Do not automatically commit, create branches, tag, publish releases, or clean user files unless the user explicitly asks.
