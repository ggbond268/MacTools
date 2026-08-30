# GitHub Actions 自动构建

本仓库提供七条流水线：

- `Build`：在 `main` push、Pull Request 和手动触发时运行。执行 XcodeGen、Debug 测试，并为每次变更编译和核对 unsigned Nightly app；在非 PR 场景还会额外编译 unsigned Release app 做配置校验。它不上传不可分发的未签名产物。
- `Prepare Release`：在 GitHub Actions 页面手动触发。输入发布类型、目标版本和是否继续发布；它会检查、bump、提交版本变更、创建 tag，并在需要时显式触发 `Release` 或 `Plugin Release`。
- `Release`：在推送 `v*.*.*` 或 `v*.*.*-*` tag，或手动输入 tag 时运行。构建 Release 版本，使用 Developer ID 签名、公证、打包 DMG，创建或更新 GitHub Release；稳定版会明确标记为 GitHub Latest，并更新官网使用的 `docs/app-release.json`，预发布不会覆盖稳定版下载元数据。
- `Nightly`：启用后每天 UTC 06:00 从 `main` 构建。它复用稳定发布已有的签名、公证、Sparkle 和插件 catalog Secrets，生成可与稳定版共存的 `MacTools Nightly.app`、同一提交的完整插件集、独立 appcast 和独立 PluginKit v5 catalog。每次运行使用唯一 `nightly-<run>-<attempt>` tag；先以 draft 上传并核对全部产物，再发布为 prerelease，绝不覆盖已有 tag 或资产。
- `Homebrew Cask Update`：手动输入版本时运行；未输入版本则从稳定 `v*` App Release 中查找同时包含 `MacTools.dmg` 与 `MacTools.sha256` 的最新版，通过 `brew bump-cask-pr` 向官方 `Homebrew/homebrew-cask` 提交 cask bump PR。
- `Plugin Release` runs for a pushed `plugins-*` tag or a manually selected plugin batch tag. Legacy PluginKit catalogs below v5 are immutable, and the schema-3 workflow rejects attempts to republish them. PluginKit v3 and later use versioned paths, the v4 catalog remains available to MacTools through 1.1.6, MacTools 1.2.0 keeps `docs/plugins/v5/catalog.json`, and hosts from 1.2.1 use `docs/plugins/v5/schema3/catalog.json`. The first release of a new ABI or schema compatibility line rebuilds and signs every plugin. Plugin batches use `--latest=false` and never replace the latest App release.
- `Deploy Pages`：在 `site/**`、`docs/app-release.json` 或 `docs/nightly/**` 合入 `main`，`Release` / `Plugin Release` / `Nightly` 成功完成，或手动触发时运行。它先构建 `site/` 下的 Astro 官网，再合并 `docs/` 中的 App 发布元数据、appcast、插件 catalog、图标库等静态发布资源并发布到 GitHub Pages；PR 不会触发这条流水线。

## 启用 Nightly（仓库维护者）

Nightly 不需要新的发布证书或私钥。合并实现后，维护者只需完成以下步骤：

1. 确认稳定版使用的九项必需 Secrets 仍然可用：`APPLE_DEVELOPMENT_TEAM`、`BUNDLE_IDENTIFIER_PREFIX`、`DEVELOPER_ID_CERT_P12`、`DEVELOPER_ID_CERT_PASSWORD`、`ASC_API_KEY_P8_BASE64`、`ASC_API_KEY_ID`、`ASC_API_ISSUER_ID`、`SPARKLE_PRIVATE_KEY` 和 `PLUGIN_CATALOG_PRIVATE_KEY_BASE64`。
2. 在 `Settings` → `Actions` → `General` 中保留 `Read and write permissions`；在 `Settings` → `Pages` 中保留 `GitHub Actions` 发布源。这两项也是现有发布流程的要求。
3. 打开 `Actions` → `Nightly`，以 `main` 手动运行一次。检查签名、公证、GitHub prerelease、`docs/nightly/appcast.xml`、`docs/nightly/plugins/v5/catalog.json` 和 Pages 部署均成功；安装该 DMG，并从 Nightly catalog 安装至少一个插件。
4. 再以 `main` 手动运行一次，在已安装的 Nightly 中验证 N → N+1 Sparkle 更新及已安装插件的启动前自动同步。通过后，在 `Settings` → `Secrets and variables` → `Actions` → `Variables` 中创建 repository variable `ENABLE_NIGHTLY_RELEASES=true`，启用每日计划任务。删除该 variable 或改为其他值即可暂停计划任务；手动运行仍可用于验证。

手动输入的 ref 必须已经属于 `origin/main`，工作流才会接触发布凭据。Nightly 使用独立 bundle ID、显示名称、`mactools-nightly://` URL Scheme、Application Support 目录、Sparkle feed 和插件 catalog；稳定版 appcast、下载元数据和插件 catalog 在发布前后都会受到路径检查。每个 Nightly 的完整插件集与 app 来自同一个 source commit，插件版本使用合法且单调递增的 `source-major.run.attempt` 格式以避免缓存复用。工作流保留最近 14 个匹配 `nightly-<run>-<attempt>` 的 prerelease，并始终额外保护当前已提交或已部署 appcast 引用的构建；稳定版和其他 prerelease 不在清理范围内。

Release assets are staged with their final public filenames before upload. A failed run deletes the draft release it created, while each successful run removes abandoned drafts in the workflow-owned `nightly-<run>-<attempt>` namespace. Published Nightly retention remains limited to matching prereleases and never selects stable releases or unrelated prereleases.

手动 `Build` workflow 产生的 Debug artifact 仍然只是 CI 调试输出，不会发布到 GitHub Releases、官网或任何 Sparkle feed，也不是第二个 Nightly 渠道。

### Nightly isolation and unchanged-run verification

The Nightly job reads the deployed `https://mactools.ggbond.app/nightly/appcast.xml`, resolves that advertised GitHub prerelease's target source SHA, and compares its tree with the selected source before accessing release credentials. It ignores generated `docs/nightly/**` changes; all other tracked changes are conservatively considered relevant. An unchanged scheduled run reports `unchanged` and skips building, signing, notarizing, release/plugin uploads, and metadata commits. A manual run always reports `publish`, including same-commit N to N+1 and rollback tests. First publication, an unavailable or malformed feed, an unusable release source, or a failed comparison defaults to publication. The check stays within the existing single job and writes no repository tracking state.

Before enabling the schedule, include these coexistence checks in the two manual runs:

1. With stable installed, install the Nightly Fan Control and Battery Charge Limit plugins. Authorize their helper installation and confirm the new files end in `.smc-helper.nightly` under `/Library/PrivilegedHelperTools`; stable helper files remain unchanged. The Nightly helper signing identifiers also end in `.nightly`.
2. Update Nightly and verify stable can still use its existing helpers without another installation prompt. Separate helpers do not isolate hardware state: test one app's fan or charging policy at a time.
3. Use separate test credentials in stable and Nightly Translator and Cloudflare R2. Confirm Nightly starts without stable credentials and that saving, updating, or deleting Nightly credentials leaves stable credentials intact.
4. Install Activity Bar hooks in both apps, in either order. Confirm both channels receive AI events. Remove Nightly's hooks and confirm stable hooks still work; reinstall Nightly's hooks, remove stable hooks, and confirm Nightly still works. Closing either app must leave the other app's listener available.
5. If testing the experimental CLI, build the standalone tool with the same `Nightly` configuration as the app. Follow `docs/testing/cli-phase-0.md` using the Nightly app and product paths; enable its broker through Nightly's settings. Verify `doctor` connects only to Nightly, and that disabling Nightly's broker leaves stable's broker registration intact. The release workflow checks the broker's embedded identifier, LaunchAgent service, and signature; the standalone prototype remains outside the published app.
6. After enabling the schedule, confirm a run with only generated `docs/nightly/**` changes reports `unchanged` without a release or metadata commit. Manual dispatch of the same source must still publish.

## 需要配置的 Secrets

进入 GitHub 仓库：`Settings` → `Secrets and variables` → `Actions` → `Repository secrets`，添加以下条目。

| Secret | 用途 |
| --- | --- |
| `APPLE_DEVELOPMENT_TEAM` | Apple Developer Team ID，用于生成 `LocalConfig.xcconfig`。 |
| `BUNDLE_IDENTIFIER_PREFIX` | Bundle ID 前缀，例如 `com.example`，最终 app id 为 `<prefix>.mactools`。 |
| `DEVELOPER_ID_CERT_P12` | Developer ID Application 证书 `.p12` 文件的 Base64 内容。 |
| `DEVELOPER_ID_CERT_PASSWORD` | 导出 `.p12` 时设置的密码。 |
| `ASC_API_KEY_P8_BASE64` | App Store Connect API Key `.p8` 文件的 Base64 内容，用于 notarization。 |
| `ASC_API_KEY_ID` | App Store Connect API Key ID。 |
| `ASC_API_ISSUER_ID` | App Store Connect Issuer ID。 |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA 私钥，必须与 `project.yml` 中的 `SPARKLE_PUBLIC_ED_KEY` 配对。 |
| `PLUGIN_CATALOG_PRIVATE_KEY_BASE64` | 插件 catalog Ed25519 私钥的 Base64 内容，用于签名当前 PluginKit 版本的 catalog。 |
| `HOMEBREW_GITHUB_API_TOKEN` | 可选。GitHub Personal Access Token，至少需要 `public_repo` 权限，仅供手动运行 `Homebrew Cask Update` workflow 时通过 `brew bump-cask-pr` 向官方 `Homebrew/homebrew-cask` 提交 cask bump PR。 |

不要把 `LocalConfig.xcconfig`、`.p12`、`.p8`、Sparkle 私钥、证书密码或 Apple ID 写入仓库。

## 准备证书 Secret

1. 在 Keychain Access 中导出 `Developer ID Application` 证书和私钥为 `.p12`。
2. 给 `.p12` 设置一个强密码，并保存到 `DEVELOPER_ID_CERT_PASSWORD`。
3. 将 `.p12` 转为单行 Base64：

```bash
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
```

4. 将剪贴板内容保存到 `DEVELOPER_ID_CERT_P12`。

## 准备公证 Secret

1. 在 App Store Connect 创建 API Key，并下载 `.p8` 文件。
2. 记录 Key ID 和 Issuer ID。
3. 将 `.p8` 转为单行 Base64：

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
```

4. 将剪贴板内容保存到 `ASC_API_KEY_P8_BASE64`。
5. 将 Key ID 保存到 `ASC_API_KEY_ID`，Issuer ID 保存到 `ASC_API_ISSUER_ID`。

## 准备 Sparkle Secret

将当前发布使用的 Sparkle EdDSA 私钥保存到 `SPARKLE_PRIVATE_KEY`。它必须与 `project.yml` 中的 `SPARKLE_PUBLIC_ED_KEY` 配对，否则旧版本应用无法验证新的更新包。

如果你只在本机钥匙串中保存了 Sparkle 私钥，请先确认能用本机 `sign_update` 签名当前 DMG；不要为了 CI 随意生成新密钥，除非你计划同时处理已发布版本的更新兼容。

## 准备插件 Catalog Secret

插件 catalog 使用独立 Ed25519 key。公钥 `PLUGIN_CATALOG_PUBLIC_KEY` 可以写入 `Release.xcconfig` 并随 app 发布；私钥必须保存到 GitHub Secret `PLUGIN_CATALOG_PRIVATE_KEY_BASE64`。

生成一对新的 catalog key：

```bash
python3 - <<'PY'
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import base64

key = Ed25519PrivateKey.generate()
private = key.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption(),
)
public = key.public_key().public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw,
)

print("PLUGIN_CATALOG_PRIVATE_KEY_BASE64=" + base64.b64encode(private).decode())
print("PLUGIN_CATALOG_PUBLIC_KEY=" + base64.b64encode(public).decode())
PY
```

不要复用 Sparkle 私钥。Sparkle key 只负责 app 更新包，插件 catalog key 只负责插件列表。

The Nightly and plugin release workflows verify this private key against the public key embedded in the app before starting expensive build or signing work. Catalog signing uses Swift/CryptoKit and the same Foundation JSON canonicalization as runtime verification, so no Python signing dependency is installed during a release.

## App 发布方式

推荐用 GitHub Actions 的 `Prepare Release` 触发完整发布准备流程：

1. 打开 `Actions` → `Prepare Release` → `Run workflow`。
2. `type` 选择 `app`。
3. `version` 输入目标版本，例如 `1.0.7`，不要带 `v`。
4. 勾选 `release` 时，准备流程会在创建 `v1.0.7` 后继续触发 `Release` workflow；不勾选时只 bump、提交并打 tag。

本地也可以用 `make release` 执行同样的准备流程：

```bash
make release
```

命令会交互选择发布类型、分析当前版本和最新 tag、选择 `patch`/`minor`/`major`，并先展示 bump 预览；确认后才自动 `git pull --rebase`、运行轻量检查、更新版本文件、提交版本 bump、创建并推送 tag。App 发布会推送 `v*.*.*` tag，后续构建、签名、公证、上传 GitHub Release、更新 Sparkle appcast 由 `Release` workflow 完成。`Release` 不更新 Homebrew；需要更新官方 cask 时，手动运行独立的 `Homebrew Cask Update` workflow。

在选择 App 或插件发布之前，`make release` 会比较最新 App tag 与当前 `Sources/MacToolsPluginKit/`。没有代码变化时直接继续；检测到变化时会列出文件，并要求发布者通过 `y/N` 明确确认是否已经检查 `pluginKitVersion`。这项兼容性确认不会被 `--yes` 跳过；非交互发布遇到 PluginKit 变化时会停止，要求改用交互终端完成检查。

非交互示例：

```bash
make release ARGS="--type app --version 1.0.7 --yes"
```

`Configs/AppVersion.xcconfig` 是 App 与内嵌 extension 的共享发布版本源。若需要手动处理，发布前先更新：

```xcconfig
MARKETING_VERSION = 0.9.3
CURRENT_PROJECT_VERSION = 15
```

功能分支若因插件兼容性检查提前声明了尚未发布的 `MARKETING_VERSION`，且该版本高于最新 `v*` tag，`make release` 会把它作为默认目标版本，并只递增 `CURRENT_PROJECT_VERSION`。显式传入相同的 `--version` 也会被接受；目标版本仍必须高于最新 tag，且不能低于源码已声明的版本。例如源码为 `1.2.0 (68)`、最新 tag 为 `v1.1.6` 时，发布计划应为 `v1.2.0 (69)`。

提交并推送版本号变更：

```bash
git add Configs/AppVersion.xcconfig
git commit -m "Bump version to 0.9.3"
git push origin main
```

然后在同一个提交上打 tag 并推送：

```bash
git tag v0.9.3
git push origin v0.9.3
```

Release 工作流会校验 `v0.9.3` 与 `Configs/AppVersion.xcconfig` 的 `MARKETING_VERSION = 0.9.3` 一致，并使用 `CURRENT_PROJECT_VERSION` 作为 Sparkle appcast 和 App 包里的 build 号。版本不一致时会直接失败，避免产物、tag 和 appcast 不一致。

也可以在 GitHub Actions 页面手动运行 `Release`，输入已存在的 tag，例如 `v0.9.3`；该 tag 指向的提交里仍必须已经更新 `Configs/AppVersion.xcconfig`。

## 插件发布方式

推荐用 GitHub Actions 的 `Prepare Release` 发布插件批次：

1. 打开 `Actions` → `Prepare Release` → `Run workflow`。
2. `type` 选择 `plugin`。
3. `version` 输入插件批次版本，例如 `1.0.9`，不要带 `plugins-`。
4. `plugin_mode` 选择 `auto`、`selected` 或 `all`；`selected` 时在 `plugins` 输入插件 ID 或目录名，多个用逗号分隔。
5. 勾选 `release` 时，准备流程会在创建 `plugins-1.0.9` 后继续触发 `Plugin Release` workflow；不勾选时只 bump、提交并打 tag。

本地也可以用 `make release` 发布插件批次：

```bash
make release ARGS="--type plugin"
```

默认 `auto` 模式会读取当前 PluginKit 版本的 catalog；首次 v3 发布时以旧 v2 catalog 作为比较基线。它会找出新插件、已手动 bump 的插件、`pluginKitVersion` 已变化的插件，以及包相关文件变化但版本未递增的插件。ABI 变化会自动切换为全量发布；对未递增的插件会按选择的 `patch`/`minor`/`major` 自动更新 `plugin.json.version`。随后命令会运行 `make generate` 和发布计划检查，提交版本 bump，推送 `plugins-*` 批次 tag。

常用非交互示例：

```bash
make release ARGS="--type plugin --version 1.0.10 --yes"
make release ARGS="--type plugin --version 1.0.10 --plugin-mode selected --plugin calendar --yes"
make release ARGS="--type plugin --version 1.1.0 --plugin-mode all --yes"
```

插件按批次单独发布，不和 app DMG 混在同一条 Release。相同 PluginKit 版本内默认是增量发布：只构建和上传本批实际变化的插件包，然后把这些新条目合并进对应的版本化 catalog。首次 ABI 升级则全量构建并生成新 catalog，旧版本 catalog 不会被覆盖。

应用内是否显示“可更新”只比较插件版本，不比较 batch tag 或 asset URL。因此只有实际变化的插件需要递增各自 `plugin.json.version`；未变化插件不会因为新批次 tag 而显示可更新或无效。

`pluginKitVersion` is the plugin ABI boundary. Raising it requires rebuilding every plugin package and incrementing each plugin's own `plugin.json.version`. The release helper automatically switches an ABI or catalog-schema compatibility migration to `plugin_mode=all` and writes a complete catalog for the new line. PluginKit v5 schema 3 writes `docs/plugins/v5/schema3/catalog.json` and does not modify the schema-2 catalog used by MacTools 1.2.0 or the v4 catalog used by earlier hosts. Catalog validation rejects mixed PluginKit versions so the host never loads a binary from an incompatible ABI.

推送插件批次 tag：

```bash
git tag plugins-1.0.1
git push origin plugins-1.0.1
```

`Plugin Release` 工作流会：

1. Read the current PluginKit catalog from `origin/main`. For the first PluginKit v5 release, use the immutable `docs/plugins/v4/catalog.json` only as the version-comparison baseline.
2. 生成增量发布计划。`auto` 模式会选择新插件和 `plugin.json.version` 高于上一版 catalog 的插件。
3. 如果插件自身源码、资源或 `pluginKitVersion` 有包相关变化，但插件版本没有递增，工作流会失败并提示需要 bump 对应 `plugin.json.version`。`MacToolsPluginKit` ABI 变化会自动切换到 `mode=all` 全量重发；展示或宿主侧改动如果也需要重发，可使用 `mode=all` 或传入特定 `--shared-path`。
4. 只以 Release 配置构建计划中的插件 target。
5. 用 Developer ID 重新签名这些插件 bundle，并打包为 `*.mactoolsplugin.zip`。
6. 创建或更新对应的 `plugins-*` GitHub Release，并只上传本批变化插件的 zip。catalog-only 变化可以创建没有 zip asset 的插件 Release。
7. 相同 ABI 内生成本批 delta catalog 并合并进该 ABI 的 catalog；ABI 首次升级则生成包含全部插件的完整 catalog。
8. Sign the catalog with `PLUGIN_CATALOG_PRIVATE_KEY_BASE64` and write it to the selected compatibility path. PluginKit v5 schema 3 writes `docs/plugins/v5/schema3/catalog.json` and never overwrites the schema-2 or v4 compatibility baselines.
9. 将对应版本化 catalog 提交回 `main`，再由 `Deploy Pages` 发布到 GitHub Pages。

如果 `auto` 模式没有发现插件包或 catalog 变化，工作流会成功结束，不创建或更新 GitHub Release。

也可以在 GitHub Actions 页面手动运行 `Plugin Release`：

- `mode=auto`：默认推荐，自动检测变化插件。
- `mode=selected`：只发布 `plugins` 输入中列出的插件 ID 或目录名，例如 `calendar,display-brightness`。
- `mode=all`：全量重建并上传当前所有插件包，适合证书、打包逻辑或插件运行时发生全局变化后的兜底发布。

插件 release asset 形态：

```text
appearance.mactoolsplugin.zip
calendar.mactoolsplugin.zip
disk-clean.mactoolsplugin.zip
```

每个 zip 内部保留目录包：

```text
appearance.mactoolsplugin/
  plugin.json
  Appearance.bundle/
```

## Release Notes 规范

App 和 Plugin Release 共用 `CHANGELOG.md` 作为唯一更新日志来源，但各自生成不同的 release notes。开发完成用户可见变更时，先添加一个简洁英文 fragment 到 `changes/unreleased/*.md`；`scripts/release.py --type app` 只消费 `release: app` fragments 并写入 `## [vX.Y.Z]`，`scripts/release.py --type plugin` 只消费 `release: plugin` fragments 并写入 `## [plugins-X.Y.Z]`。已消费 fragments 会在发布提交中删除。随后对应 workflow 从 tag 对应的 `CHANGELOG.md` 段落提取 Markdown：App notes 写入 GitHub Release，Plugin notes 写入插件批次 GitHub Release。Sparkle appcast 使用单独生成的英文说明，在 `App Updates` 后附加自上一个 App 版本以来发布的插件条目，并按 changelog 类型合并到 `Plugin Updates`；没有插件更新时省略该分组，因此不会改变 GitHub Release 的日志内容。

Release preparation also regenerates `Sources/Resources/ReleaseHistory.json` from the same canonical Markdown as the complete offline App and Plugin history. About displays the 10 most recent entries. Treat the JSON as generated output; after an intentional historical edit, rebuild it with `python3 scripts/changelog.py export-history`.

fragment 使用简化的 front matter：

```markdown
---
release: app
type: fixed
area: Finder Integration
---

Finder right-click menu items now stay hidden when the plugin is disabled.
```

`release` 必须是 `app` 或 `plugin`，决定哪类发布会消费该 fragment。`type` 会映射到 Keep a Changelog 风格分组：

| Type | Release 分组 | 用途 |
| --- | --- | --- |
| `summary` | `Summary` | 版本顶部的一句话产品摘要，通常发布前再补。 |
| `added` | `Added` | 新功能、用户可感知的新能力。 |
| `changed` | `Changed` | 行为、交互、文案或默认值变化。 |
| `fixed` | `Fixed` | Bug 修复、稳定性修复。 |
| `security` | `Security` | 安全相关修复。 |
| `removed` | `Removed` | 已移除能力或兼容性。 |
| `deprecated` | `Deprecated` | 即将移除或不推荐继续使用。 |
| `maintenance` | `Maintenance` | 维护者需要知道的构建、发布或依赖变化。 |

更新日志应面向用户或维护者可读，保持英文、短句、少量信息密度。不要把 git log、实现细节、测试重构、重复描述或长篇背景写进 fragment。多个 fragment 内容完全相同时，发布脚本会按文本去重；语义重复仍应由 agent 在提交前合并成一条更好的描述。

如果同一个修改同时影响 App 发布和插件批次发布，应写两份 fragment：`release: app` 描述宿主或 App 层面的影响，`release: plugin` 描述插件包层面的影响。不要把同一句复制到两个 release channel；如果用户只需要在其中一个发布说明里看到该变化，就只写对应的 fragment。

发布版本本身的提交，例如 `chore: release v1.0.28`，不需要 fragment。

如果某个版本需要像产品公告一样在自动列表上方放一段手写摘要，可以在推 tag 前添加：

```text
.github/release-highlights/v0.14.0.md
```

文件内容会被原样置顶到 `CHANGELOG.md` 中提取的 release notes 前。没有对应文件时，Release 工作流只使用 `CHANGELOG.md` 当前版本段落。该文件也会同步进入 Sparkle 更新弹窗。

运行 `Homebrew Cask Update` 时，工作流会从稳定 `v*` App Release 中筛选同时包含 `MacTools.dmg` 和 `MacTools.sha256` 的版本，再通过 `brew bump-cask-pr mactools --version ... --sha256 ...` 向官方 `Homebrew/homebrew-cask` 打开版本更新 PR。不要传入 GitHub release asset 的展开下载 URL；官方 cask 应保留 `v#{version}` URL 模板，否则 Homebrew audit 会把它当成未版本化 URL。预发布和 `plugins-*` 批次不会被选中；未配置 secret 时可手动提交 Homebrew PR。Homebrew PR 合并后，用户本地运行 `brew update` 后即可通过 `brew upgrade --cask --greedy mactools` 检测到新版本。

仓库设置中需要允许 workflow 写入：`Settings` → `Actions` → `General` → `Workflow permissions` 选择 `Read and write permissions`。

## GitHub Pages 发布源

为了避免普通 `main` push 触发 GitHub 内置的 `pages-build-deployment`，需要在仓库设置里把 Pages 发布源改为 Actions：

1. 进入 `Settings` → `Pages`。
2. 在 `Build and deployment` → `Source` 选择 `GitHub Actions`。
3. 保存后由本仓库的 `Deploy Pages` workflow 负责发布 `docs/`。

如果 Pages 仍配置为 `Deploy from a branch`，GitHub 会继续在所选分支有提交时自动运行内置的 `pages-build-deployment`。这个内置流水线不是由仓库里的 workflow YAML 控制的，不能只靠修改 `.github/workflows/` 禁止。

## 安全策略

- PR 构建不读取发布 Secrets，只执行未签名构建和测试。
- Release 工作流只使用 `contents: write` 创建或更新 GitHub Release，并把 `docs/appcast.xml` 与 `docs/app-release.json` 提交回 `main`；普通 Build 工作流只有 `contents: read`。
- The Plugin Release workflow uses `contents: write` only to create or update a plugin batch release and commit the signed catalog to `main`. The v4 and PluginKit v5/schema-2 catalogs remain available to released hosts while schema-3 PluginKit v5 releases write `docs/plugins/v5/schema3/catalog.json`.
- Deploy Pages 工作流在官网源码或 App 下载元数据合入 `main`、Release / Plugin Release 成功后发布站点，使用 `contents: read`、`pages: write` 和 `id-token: write`。
- 签名证书导入临时 keychain，任务结束后清理。
- App Store Connect `.p8`、Sparkle 私钥和插件 catalog 私钥只写入 runner 临时目录或进程环境，使用后删除。
- 日志不主动输出 Team ID、Bundle 前缀、证书名称、私钥或证书内容。
