# MacTools Plugin Catalog

MacTools dynamic plugins use one catalog-driven flow for both production distribution and local development.

- PluginKit 2 production builds read the legacy `catalog.json` URL. PluginKit 3 and later builds read versioned URLs. MacTools through 1.1.6 remains on immutable PluginKit v4, MacTools 1.2 uses immutable PluginKit v5, and the CLI-capable host uses PluginKit v6 at `v6/catalog.json`.
- Each catalog contains packages for one PluginKit ABI line. The legacy v2 catalog is kept unchanged when a new ABI is released, so older app builds continue to work.
- `minimumHostVersion` at the catalog root is the oldest host that can parse that catalog schema. Each entry declares its own install requirement; older hosts keep the catalog available and show newer entries as incompatible instead of rejecting the whole marketplace.
- Local development reads a Debug-only `file://` catalog, usually configured with `MACTOOLS_PLUGIN_CATALOG_URL`.
- Both flows resolve catalog entries into local staged packages, verify checksum and manifest compatibility, then install through the same package store. The marketplace can update one plugin at a time or run a batch update for every currently updateable plugin.

## Catalog v2

```json
{
  "schemaVersion": 2,
  "catalogID": "com.ggbond.mactools.plugins",
  "generatedAt": "2026-05-16T12:00:00Z",
  "minimumHostVersion": "1.2.0",
  "pluginKitVersion": 6,
  "plugins": [
    {
      "id": "com.ggbond.mactools.demo",
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
      "minimumHostVersion": "1.2.0",
      "pluginKitVersion": 6,
      "capabilities": {
        "primaryPanel": true,
        "componentPanel": false,
        "settings": "form"
      },
      "permissions": [],
      "package": {
        "url": "https://github.com/ggbond268/MacTools/releases/download/plugins-1.0.1/Demo.mactoolsplugin.zip",
        "sha256": "...",
        "size": 1234567
      },
      "releaseNotesURL": "https://github.com/ggbond268/MacTools/releases/tag/plugins-1.0.1",
      "category": "productivity",
      "releaseChannel": "beta"
    }
  ],
  "revoked": [],
  "signature": {
    "algorithm": "ed25519",
    "value": "..."
  }
}
```

`localizedMetadata` is copied from each plugin manifest and is used by the marketplace before the plugin bundle is loaded. `displayName` and `summary` remain required fallbacks for older hosts and incomplete translations.

Catalog schema 2 follows PluginKit 4 and later manifests: `capabilities.settings` is `none`, `form`, or `workspace`. Schema 1 and its boolean `configuration` capability remain in older ABI catalogs and are not rewritten. A newer host may decode an installed package from an older ABI only far enough to identify and update it; it never loads or renders an incompatible settings API.

Release catalogs must include an Ed25519 signature. Debug local catalogs may omit `signature`, but they still go through package checksum, manifest, staging, and same-team code signature validation. Catalog verification validates every entry's identity and PluginKit ABI without requiring every package to support the current host. Package installation and loading continue to enforce the entry's `minimumHostVersion` strictly.

For an app version that switches to a new production catalog URL, release order is enforced: publish the compatible plugin batch first, wait for Pages to deploy the committed signed catalog, then prepare and publish the app. `scripts/plugins/preflight-app-plugin-catalog.swift` checks that the production URL returns the same nonempty, signed PluginKit catalog committed in the release ref. Both `scripts/release.py --type app` and the final app release workflow run this preflight, so the app cannot be published while its catalog is missing, stale, unsigned, or invalid.

## Versioned Catalog URLs

The catalog URL is selected by the host's supported PluginKit version:

```text
PluginKit 2 -> https://mactools.ggbond.app/plugins/catalog.json
PluginKit 3 -> https://mactools.ggbond.app/plugins/v3/catalog.json
PluginKit 4 -> https://mactools.ggbond.app/plugins/v4/catalog.json
PluginKit 5 -> https://mactools.ggbond.app/plugins/v5/catalog.json
PluginKit 6 -> https://mactools.ggbond.app/plugins/v6/catalog.json
PluginKit N -> https://mactools.ggbond.app/plugins/vN/catalog.json
```

The first release for a new PluginKit version uses the previous ABI catalog only as a comparison baseline. It publishes a complete catalog containing every rebuilt plugin under the new versioned path. Later releases for the same PluginKit version may use incremental merges within that path. Never overwrite an older ABI catalog with newer packages.

## Local Development

The default local workflow is convention based:

```text
MacTools/
  Plugins/
    Demo/
      plugin.json
      Sources/
      Bundle/
      Tests/
```

External plugin repositories can use the same structure, as long as the manifest can resolve either a buildable project or a prebuilt bundle:

```text
MacToolsPlugins/
  Demo/
    plugin.json
    Sources/
    Bundle/
    Tests/
```

`plugin.json` declares the plugin ID, version, capabilities, bundle path, optional `releaseChannel`, and build scheme. In this repository `make generate`, `make build`, `make run`, and `make build-plugin` first scan `Plugins/*/plugin.json` and generate the local XcodeGen plugin targets. External repositories may provide their own `project.yml`, `.xcodeproj`, or the declared bundle directory. The built package contains only `plugin.json` and the signed `.bundle`; extra executables must already be copied into the bundle resources and listed in `plugin.json.package.signPaths` when they require an individual code signature.

From the MacTools repository, build all local plugins and generate the Debug catalog:

```bash
make build-plugin
```

Or build one plugin by directory name or plugin ID:

```bash
make build-plugin PLUGIN=Demo
make build-plugin PLUGIN=com.example.mactools.demo
```

Generated output lives under:

```text
build/LocalPlugins/
  Packages/*.mactoolsplugin
  catalog.dev.json
```

Then run MacTools:

```bash
make run
```

`make run` stages and verifies the latest Debug bundle at `~/Applications/MacTools Dev.app` with rollback on failure, then starts that installed executable directly so the catalog environment variable reaches the app process. If `MACTOOLS_PLUGIN_CATALOG_URL` is not already set and `build/LocalPlugins/catalog.dev.json` exists, Make uses that file automatically. Use `make install-debug-app` when the stable bundle should be updated without launching it.

You can override the fixed directories:

```bash
make build-plugin LOCAL_PLUGIN_SOURCE_DIR=/path/to/plugins LOCAL_PLUGIN_BUILD_DIR=/path/to/build
make run MACTOOLS_PLUGIN_CATALOG_URL=file:///path/to/catalog.dev.json
```

For Debug runs, the catalog URL scheme selects the verification mode. A `file://` URL uses the local development catalog policy, where signatures are optional. An `https://` URL uses the production catalog policy, where the catalog signature is required:

```bash
make run MACTOOLS_PLUGIN_CATALOG_URL=https://mactools.ggbond.app/plugins/catalog.json
```

The app copies the package into its own staging and installed directories. Uninstall deletes only the installed copy under MacTools application support; it never deletes the plugin source directory or the local build directory.

## Release Flow

Recommended production flow is an incremental batch plugin release:

1. Run `make release`.
2. Choose `plugin`, release mode, and `patch`/`minor`/`major`.
3. The helper analyzes the production catalog and shows the planned manifest bumps.
4. After confirmation, the helper syncs `main`, bumps changed plugin manifests when needed, compiles `release: plugin` changelog fragments into `CHANGELOG.md`, runs a release plan check, commits the bump, and pushes a batch tag such as `plugins-1.0.1`.
5. The `Plugin Release` GitHub Action reads the catalog for the current PluginKit version. The first release of a new ABI may fall back to the previous catalog only to compare versions.
6. In default `auto` mode, the workflow selects new plugins, plugins whose manifest version is higher than the previous catalog entry, and every plugin when shared `Sources/MacToolsPluginKit/` code changed since its previous package was built.
7. If package-relevant files changed inside a plugin or shared PluginKit code changed but that plugin version did not increase, the workflow fails before signing or uploading. A `pluginKitVersion` change automatically becomes a full `mode=all` rebuild and replaces the catalog for that ABI line; other exceptional shared paths can still be supplied explicitly with `--shared-path`.
8. The workflow builds, signs, zips, and uploads only the selected plugin packages.
9. For an ABI migration, the workflow generates a complete catalog from all rebuilt packages. For later releases within an ABI line, it generates a delta catalog and merges it into that line's catalog, keeping unchanged entries pointing at their existing assets.
10. The signed catalog is committed to `docs/plugins/catalog.json` for v2 or `docs/plugins/vN/catalog.json` for PluginKit N >= 3. PluginKit v6 writes `docs/plugins/v6/catalog.json` and never mutates the v5 compatibility catalog.
11. `Deploy Pages` publishes the signed catalog to GitHub Pages.

The batch tag is stored per plugin entry through `package.url` and `releaseNotesURL`, so one catalog can point different plugins to different release tags without changing host code.
Plugin batch releases are published with `--latest=false`; only stable `v*` App releases may become the repository's GitHub Latest release.

The GitHub Release body for each plugin batch is extracted from the matching `CHANGELOG.md` entry, such as `## [plugins-1.0.1]`.

An incremental release record contains only packages changed in that batch:

```text
GitHub Release: plugins-1.0.1
  calendar.mactoolsplugin.zip
  display-brightness.mactoolsplugin.zip
```

Unchanged plugin entries remain valid because the catalog preserves their previous URLs, checksums, and versions. They are not shown as updates in the app unless their catalog version is higher than the installed version.

`pluginKitVersion` is the PluginKit ABI boundary. When it changes, every plugin package must be rebuilt and each plugin's manifest version must increase during release so installed users see an update. The standard `make release` flow handles these manifest bumps automatically. The new host reads the new catalog and updates all installed plugins before loading any dynamic bundle. The catalog merge step rejects mixed PluginKit versions.

Within one PluginKit ABI line, a plugin that adopts a newly exported PluginKit type must set `minHostVersion` to the first MacTools app release that exports that symbol. This prevents an older host from accepting the manifest and then failing while loading the dynamic bundle.

Any change under `Sources/MacToolsPluginKit/` is conservatively treated as package-relevant for every plugin. `make release` automatically bumps the affected manifests in the release commit; feature PRs should not pre-bump unrelated plugins. This prevents an incremental catalog from retaining binaries built against an older copy of the shared framework.

When a full rebuild is needed, run the `Plugin Release` workflow manually with `mode=all`. To publish a controlled subset, use `mode=selected` and pass comma-separated plugin IDs or directory names in `plugins`.

Each zip keeps the package root:

```text
appearance.mactoolsplugin/
  plugin.json
  Appearance.bundle/
    Contents/
      Info.plist
      MacOS/Appearance
      Resources/
      _CodeSignature/
```

Local dry-run packaging uses the same release asset script:

```bash
make package-plugins-release \
  PLUGIN_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  PLUGIN_CATALOG_PRIVATE_KEY_BASE64="$PLUGIN_CATALOG_PRIVATE_KEY_BASE64" \
  PLUGIN_RELEASE_TAG=plugins-1.0.1
```

Generated local output:

```text
build/PluginRelease/
  Assets/*.mactoolsplugin.zip
  catalog.json
docs/plugins/v6/catalog.json
```

The lower-level scripts are still useful for external plugin repositories. `build-plugin-release-assets.sh` can build all plugins or a subset with repeated `--plugin` arguments:

```bash
scripts/plugins/plan-plugin-release.py \
  --mode all \
  --previous-catalog docs/plugins/catalog.json \
  --output build/PluginRelease/plan.json

scripts/plugins/build-plugin-release-assets.sh \
  --base-url https://github.com/ggbond268/MacTools/releases/download/plugins-1.0.1 \
  --catalog-output build/PluginRelease/catalog.delta.json \
  --sign-identity "Developer ID Application: Example (TEAMID)"

scripts/plugins/merge-plugin-catalog.py \
  --previous docs/plugins/catalog.json \
  --updates build/PluginRelease/catalog.delta.json \
  --plan build/PluginRelease/plan.json \
  --plugin-kit-version 3 \
  --output build/PluginRelease/catalog.merged.json

scripts/plugins/generate-plugin-catalog.sh \
  --mode release \
  --base-url https://github.com/ggbond268/MacTools/releases/download/plugins-1.0.1 \
  --output dist/catalog.json \
  --package dist/Demo.mactoolsplugin.zip \
  --release-notes-url https://github.com/ggbond268/MacTools/releases/tag/plugins-1.0.1

scripts/plugins/sign-plugin-catalog.sh \
  --input build/PluginRelease/catalog.merged.json \
  --output docs/plugins/v3/catalog.json \
  --private-key-base64 "$PLUGIN_CATALOG_PRIVATE_KEY_BASE64"
```

The catalog private key, Developer ID identity, and GitHub token must come from local environment variables or CI secrets. Do not commit them. The catalog public key is safe to embed in the app as `PLUGIN_CATALOG_PUBLIC_KEY`.

## Runtime Lifecycle

Install, update, and uninstall are immediate at the UI contribution level:

- Installed plugins contribute every panel, component, settings, permission, and shortcut surface they support.
- Uninstalled plugins are removed from UI immediately and package files are deleted. Scoped plugin data is retained so a later reinstall can recover it; a separate destructive data-removal flow may be added in the future.
- Batch updates resolve the currently updateable catalog entries and rebuild plugin management state once after successful package replacements.
- A declared feature-extraction migration may install its replacement package before updating the installed source package that retires the feature. Automatic migration requires the legacy preference marker; manually installing the destination also coordinates an older source even when that preference is not yet present. The host resolves both catalog packages before mutation, suspends a loaded source, installs and runtime-validates/activates the replacement, then retires the source. A validation or paired-update failure removes the new destination and restores the old loaded source. A completion marker makes the bridge one-time; completion is persisted before the write-ahead journal is cleared, and startup reconciles a stale journal left beside durable completion. If the source is explicitly uninstalled during recovery, the host durably records that intent before deleting its package; a later launch finishes the removal instead of reinstalling the source.
- Already-loaded native code is not force-unloaded in-process. The executable code is fully released after the app restarts.

This keeps the native bundle lifecycle aligned with macOS loadable bundle constraints while preserving a predictable management UI.
