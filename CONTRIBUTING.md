# Contributing to MacTools

**English** · [简体中文](CONTRIBUTING.zh-CN.md)

Help improve a native, lightweight macOS utility collection. Bug fixes, plugins, translations, documentation, and focused UI improvements are welcome. Keep each pull request about one problem and verify the behavior you change.

## Before you start

Search [existing issues](https://github.com/ggbond268/MacTools/issues) and pull requests first. Discuss new plugins, public PluginKit APIs, and substantial interaction changes in an issue before implementation. Describe the user need, proposed behavior, and tradeoffs. Prefer English for commit messages and PR titles; clear reports in Chinese are also welcome.

### Issue format

Use the [Bug report](.github/ISSUE_TEMPLATE/bug_report.yml) or [Feature request](.github/ISSUE_TEMPLATE/feature_request.yml) form. Give the title a concrete symptom or outcome, such as “Calendar panel does not refresh after wake.”

| Report | Include |
| --- | --- |
| Bug | Reproduction steps or observations, expected and actual behavior, frequency, app version/channel, plugin version, macOS version, and Mac chip. Add relevant displays, devices, permissions, or logs. |
| UI issue | A screenshot showing the affected panel or window; a short recording for interaction problems. Include app language, appearance, and display scaling when relevant. |
| Performance issue | The workload, whether the panel is open or closed, approximate duration, and CPU/memory/Energy Impact observations. Include a baseline when available. |
| Feature or plugin | The problem and use case, proposed interaction, current workaround, alternatives, and required system access. |

Remove credentials, private content, and identifying account details from attachments. Report one problem per issue; link related reports instead of duplicating them.

## Build and run

Use macOS, an Xcode toolchain supporting Swift 6, and XcodeGen. The app targets macOS 14+; individual APIs may require newer versions. The [Build workflow](.github/workflows/build.yml) defines the CI environment.

```bash
brew install xcodegen
make setup
```

Fill in `DEVELOPMENT_TEAM` and a stable `BUNDLE_IDENTIFIER_PREFIX` in the generated `LocalConfig.xcconfig`, then run:

```bash
make run
```

This builds the app and plugins, syncs the Debug catalog, and installs `~/Applications/MacTools Dev.app`. A full Debug sync moves packages absent from the checkout into a recoverable quarantine; a filtered sync preserves unrelated packages.

| Command | Purpose |
| --- | --- |
| `make generate` | Generate plugin targets and the Xcode project. Use this instead of bare `xcodegen generate`. |
| `make build` | Compile the app and its plugin targets. |
| `make sync-debug-plugins PLUGIN=calendar` | Build the app targets, then sync only the selected Debug plugin without launching the app. |
| `make build-plugin PLUGIN=calendar` | Validate a standalone plugin package and its Debug catalog. |

Keep local configuration, credentials, generated projects, and build products out of commits. See [local plugin development](docs/plugins/local-native-plugins.md) for package setup and debugging.

## Where changes belong

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | Menu-bar panels, settings, windows, and app routing. |
| `Sources/Core/` | Plugin hosting, actions, permissions, shortcuts, storage, and updates. |
| `Sources/MacToolsPluginKit/` | Shared plugin protocols, declarative UI, and runtime context. |
| `Plugins/<PluginName>/` | `plugin.json`, `Sources/`, `Bundle/`, resources, and adjacent `Tests/`. |
| `Tests/` | Shared App/Core tests. |
| `docs/plugins/` | Feature contracts and plugin development guides. |

Ordinary plugins do not need root `project.yml` edits. Put necessary build overrides in the plugin's own `project.yml`; app extensions such as Finder Sync must be embedded by the host.

## Development standards

Follow the [plugin development standards](docs/plugins/development-guidelines.md) and the adjacent implementation. The common requirements are:

- **Respect the host contract.** Implement `MacToolsPlugin`, publish stable `panelItems`, and keep manifest capabilities, action policies, permissions, and minimum-host requirements consistent with runtime behavior. Reuse host actions and shortcuts.
- **Match the product.** Use declarative settings and host renderers, `PluginSettingsTheme`, and `PluginComponentTheme`. Keep typography, spacing, controls, focus behavior, and error states consistent. Localize user-facing copy and verify long labels.
- **Build reusable widgets.** Support zero or multiple placements, isolated previews, view recycling, and independent per-placement presentation state. See [panel items](docs/plugins/panel-items.md).
- **Keep background work economical.** Use cached snapshots, event-driven updates, bounded asynchronous work, and visibility-aware presentation. Preserve intentional monitoring while hidden; stop owned work on deactivation. See [performance requirements](docs/plugins/development-guidelines.md#performance-and-energy).
- **Preserve user control.** Handle denied permissions, cancellation, unsupported hardware, and system changes. Keep existing confirmations, recovery paths, and destructive-operation safeguards.

## Validation

Cover core outcomes and real regression risks. Reuse existing tests; add or update a focused test when a changed behavior is not already protected. Prioritize the main use case and consequential boundaries such as data loss, permission checks, cancellation, or compatibility when affected.

There is no per-PR test-count or coverage-percentage target. Do not add tests that merely repeat the implementation, assert private call sequences, or check fixed wording, colors, and spacing. Documentation and cosmetic-only changes normally need review and visual verification, not new automated tests.

Run the smallest relevant test class or method. For example:

```bash
xcodebuild -project MacTools.xcodeproj -scheme MacTools \
  -configuration Debug -derivedDataPath build/DerivedData \
  test -quiet -only-testing:MacToolsTests/ComponentPanelLayoutTests
```

Replace the selector with the tests for your change; omit it for the full suite when the scope warrants it. Use temporary directories, fixtures, and fake services rather than real user data or accounts. Broaden validation only for failures, shared contracts, or other affected behavior. Once the relevant checks pass, repeat them only after new changes, failures, or an uncovered risk.

| Change | Verification scope |
| --- | --- |
| App or plugin behavior | Compile and run relevant existing tests. Add coverage only for missing core behavior or a regression; manually check hardware/system integration where needed. |
| UI or widgets | Attach the UI evidence below. Check affected interactions; add logic tests only when state, actions, or lifecycle change. |
| PluginKit API/ABI or cross-module behavior | `make ci` before pushing these code changes; it includes script tests, XCTest, and frozen-client compatibility. Register newly introduced APIs in `scripts/tests/test_plugin_minimum_host_compatibility.py`; consumers of already listed APIs need a compatible `minHostVersion`, not another inventory entry. |
| Scripts, manifests, or catalogs | Focused script tests for isolated logic; `make script-tests` for package/schema/compatibility changes or new public API consumers. Regenerate website data with `python3 scripts/plugins/generate_website_plugin_data.py` after metadata/action changes. |
| Panel drag routing or hit testing | Run `make build` first, then the affected [native interaction scenario](docs/testing/panel-layout-editing.md). Use `--compile-only` for compilation checks or `make panel-layout-ui-tests` for all scenarios. Native interaction requires an active desktop and is separate from CI. |
| Changelog fragments | `make validate-changelog` before committing or pushing. |
| Documentation only | Check changed links, examples, formatting, and rendered layout; no app build is needed. |

## Submit a pull request

Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Explain the problem, resulting behavior, verification, and relevant limitations. Link the issue and keep unrelated refactoring or formatting out of the diff. Contributors remain responsible for understanding and testing all submitted code, including assisted code.

**UI changes require before/after screenshots.** For a new surface, provide the resulting UI and describe its entry point. Include light and dark appearances for visual changes and a representative custom theme when theme behavior changes. Use a short recording for dragging, focus, keyboard navigation, or other behavior a still image cannot demonstrate. Show enough of the surrounding window to assess layout; remove private content.

Check the interactions, states, translations, and window sizes affected by the change; this is not an exhaustive checklist for every PR. Include a comparable before/after observation when changing background workload, sampling frequency, large-data rendering, or claiming a performance improvement; routine UI edits do not need profiling. See the [measurement guide](docs/plugins/development-guidelines.md#performance-and-energy).

Before requesting review:

- [ ] Relevant checks pass; the PR lists commands, results, and any checks that could not run.
- [ ] UI evidence is attached when applicable, and the design follows shared components and themes.
- [ ] User-visible changes update the README or feature guide and include an English fragment in `changes/unreleased/`.
- [ ] Manifest metadata, API compatibility, permissions, and action policies match the implementation.
- [ ] Third-party sources and licenses are recorded; no secrets, local configuration, or unrelated generated files are included.

Changelog fragments use `release: app` or `release: plugin` and a supported `type`. Keep each entry within 220 characters and two sentences. If both channels are affected, explain each impact separately. Documentation-only changes do not need a release fragment. See [changelog instructions](changes/README.md).

## Licensing and releases

Contributions must follow [LICENSE](LICENSE) and [LICENSING.md]. Project-authored app, CLI, PluginKit, official plugins, tooling, and documentation use **GPL-3.0-only**. Submit only material you have the right to contribute under the applicable terms. Third-party material retains its own notices; record its source, exact revision, affected products, source paths, and license text in [ThirdPartyNotices](Sources/Resources/ThirdPartyNotices/manifest.json). Plugins accepted into the official catalog must use GPLv3-compatible terms unless the licensing policy documents an exception. Icon contributions also follow the [asset catalog rules](docs/icon-gallery.md).

Releases are maintainer-owned. Feature PRs should not pre-bump plugin versions, change signed catalogs, or regenerate release history. Follow the [release workflow](docs/github-actions.md), [plugin catalog](docs/plugins/plugin-catalog.md), and [CLI release gates](docs/plugins/cli-release.md) for release work.
