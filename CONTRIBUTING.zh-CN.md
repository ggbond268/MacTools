# Contributing to MacTools

[中文] <a href="CONTRIBUTING.md">[English]</a>

感谢你关注 MacTools。请让每次贡献保持小而清晰：说明问题、给出可验证改动，并避免混入无关重构。

## 贡献方式
- Bug 报告请包含复现步骤、期望结果、实际结果、macOS 版本和相关日志或截图。
- 功能建议请说明使用场景、目标用户和预期交互；大型插件或交互变更请先开 issue 对齐范围。
- 涉及磁盘删除、系统权限、全局快捷键、显示器控制、签名或更新流程的改动，需要说明风险、保护措施和回滚方式。

## 开发环境
- 需要 Xcode 和 `xcodegen`，项目最低支持 macOS 14.0。
- 首次初始化：运行 `make setup`，再编辑 `LocalConfig.xcconfig`，填写 `DEVELOPMENT_TEAM` 和稳定、非占位的 `BUNDLE_IDENTIFIER_PREFIX`。任一值缺失时，Debug 构建会提前失败，避免 macOS 注册格式错误的重复应用身份。
- 本地测试请使用 `make run`。它会把唯一的 Debug 应用安装到 `~/Applications/MacTools Dev.app`，并从 LaunchServices 注销其他 `MacTools Dev` 构建副本。
- 常用命令：`make generate` 生成 Xcode 项目，`make build` 编译校验，`make run` 本地运行。
- 插件开发：`make run` 会增量编译 App 和插件，并把最新 Debug 插件包同步到本地开发市场；`make sync-debug-plugins` 可只同步已编译插件。`make build-plugin` 保留给单独验证动态包或发布链路使用，指定插件可运行 `make build-plugin PLUGIN=calendar`。
- 不要提交本地或生成文件：`MacTools.xcodeproj`、`MacTools.xcworkspace`、`LocalConfig.xcconfig`、`build/`、`scripts/release.local.env`。

## 项目结构
- `Sources/App/`：应用入口、菜单栏状态项、设置页和窗口路由。
- `Sources/Core/`：插件宿主、动态插件加载、快捷键、权限、日志、更新等共享基础能力。
- `Sources/MacToolsPluginKit/`：插件 API、描述式 UI 模型和运行时上下文。
- `Plugins/<PluginName>/`：插件 manifest、源码、bundle 入口、资源和相邻测试。
- `Tests/`：App/Core 共享逻辑的 XCTest；插件测试优先放在对应插件目录下。
- `project.yml`：XcodeGen 根项目源文件，只维护 App、PluginKit 和公共聚合入口；插件 target 由生成器自动生成。
- `Plugins/<PluginName>/project.yml`：可选的插件构建差异配置，仅在插件需要额外 framework、include path、bundle 资源、helper/tool target 或 target 覆盖时添加。
- `docs/plugins/`：插件包、catalog、本地调试和发布流程说明。
- `docs/superpowers/`：较大的产品、交互或实施设计文档。

## 开发约定
- 新增插件放在 `Plugins/<PluginName>/`，至少包含 `plugin.json`、`Sources/` 和 `Bundle/`。
- 普通插件只需要在目录内定义 `plugin.json`、源码和 bundle 入口；`make generate` 会扫描 `Plugins/*/plugin.json` 并生成本地 `Configs/GeneratedPlugins.yml`，不要手改生成文件。
- 需要 macOS app extension 的能力（如 Finder Sync）必须在根 `project.yml` 添加扩展 target 并嵌入主应用；动态插件只负责 MacTools 面板和设置入口。
- 新增和更新插件的命令流程见 `docs/plugins/local-native-plugins.md` 的 Development Steps。
- 文档保持简短、聚焦任务。用户可见行为变化应同步更新 `README.md` 或 `docs/` 下的相关文档；插件包、catalog 或发布流程变化应更新 `docs/plugins/`。
- 插件实现 `MacToolsPlugin`；菜单栏主面板实现 `PluginPrimaryPanel`，组件面板实现 `PluginComponentPanel`。
- `plugin.json.id` 必须稳定、可读，并与运行时 `PluginMetadata.id` 完全一致；每个插件包只返回一个插件实例。
- 插件展示状态通过 `PluginPanelState`、`PluginPanelDetail`、`PluginPanelControl` 等模型表达，不绕过现有面板框架。
- 插件设置优先使用 `settingsSections`、`permissionRequirements`、`shortcutDefinitions` 等描述式模型；只有复杂管理器或专用交互才使用 `PluginConfiguration` 自定义视图。
- 普通插件资源文件如果依赖变更较少，推荐直接打包到可执行二进制中；需要额外 bundle 资源时，在插件自己的 `project.yml` 中声明最小差异。
- 自定义插件设置视图必须复用 `MacToolsPluginKit.PluginSettingsTheme` 和 `.pluginSettingsCardBackground(...)`，不要复制插件私有 settings style，也不要让插件依赖 `Sources/App/SettingsStyle.swift`。
- 插件状态变化后调用 `onStateChange?()`；耗时扫描、文件系统和系统调用不要长时间阻塞主线程。
- 用户可见文案以中文为主，保持简洁、清楚、接近 macOS 原生表达。
- 用户可见文案使用 `.xcstrings` 本地化。App/Core 文案放在 `Sources/Resources/Localization`，PluginKit 文案放在 `Sources/MacToolsPluginKit/Resources`，插件文案放在 `Plugins/<PluginName>/Resources`。插件 `plugin.json` 保留 `displayName`/`summary` 作为 fallback，并为插件市场和未加载插件展示提供 `localizedMetadata`。
- 新插件应尽量提供多语言，至少覆盖面板文案、设置文案、权限说明和插件元数据。
- 优先复用 Apple 原生框架；新增系统 framework、私有 include path、bundle 内辅助可执行文件时，在插件自己的 `project.yml` 中声明最小差异。需要单独签名的 bundle 资源可执行文件应写入 `plugin.json.package.signPaths`。

## 测试
- 行为改动应补充或更新相邻 XCTest，测试文件命名使用 `<TypeName>Tests.swift`。
- 完整测试：`xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet`。
- 单个测试类：在完整测试命令后追加 `-only-testing:MacToolsTests/<TestClassName>`。
- 文件系统测试使用临时目录或 fake store；磁盘清理相关测试不得删除真实用户目录。

## Pull Request Checklist
- PR 范围聚焦，并说明变更目的、验证方式和用户影响。
- commit message、Pull Request 标题/描述和 issue 优先使用英文。
- 构建或测试已通过；如无法运行，请在 PR 中说明原因。
- 用户可见行为变化已同步更新 `README.md` 或相关设计文档。
- 高风险功能已覆盖安全校验、错误状态和权限不足场景。
- 不包含无关格式化、生成物、本地配置、证书或发布凭证。

## Release
- 发布由维护者执行；不要在普通贡献中创建 tag、发布 GitHub Release 或提交发布产物。
- GitHub 页面发包优先使用 `Actions` → `Prepare Release`。输入 `type`、目标 `version` 和是否 `release`；勾选 `release` 时会在 bump、提交和创建 tag 后继续触发实际发包 workflow。
- 快速发包优先使用 `make release`。命令会交互选择 `app` 或 `plugin`，先分析下一版本的 `patch`/`minor`/`major` 并预览 bump；确认后才 `git pull --rebase`、执行轻量检查、更新并提交版本 bump、创建并推送对应 tag。
- App 发布会更新 `Configs/AppVersion.xcconfig` 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，推送 `v*.*.*` tag 后由 `Release` workflow 构建、签名、公证、上传 DMG，将稳定 App Release 标记为 GitHub Latest，并更新 Appcast 和官网下载元数据。
- 公开 Nightly 发布是由维护者执行的 `main` 快照，使用独立的应用身份、存储范围、更新源和同一提交构建的完整插件 catalog。Nightly 插件版本由流水线生成为 `source-major.run.attempt`，功能贡献不应因 Nightly 预先 bump 源 manifest。两次手动更新验证通过后，维护者可设置 `ENABLE_NIGHTLY_RELEASES=true` 启用每日计划。
- 插件发布会推送 `plugins-*` 批次 tag。默认 `auto` 模式会按生产 catalog 找出新插件、已 bump 插件和包相关变更插件；需要时自动更新对应 `plugin.json.version`，然后由 `Plugin Release` workflow 构建并合并签名 catalog。插件批次 Release 不会标记为 GitHub Latest。
- 新版 App 首次启动时会先检查已安装插件，并从签名后的生产 catalog 自动更新到最新版；不会自动安装用户未安装的新插件。
- 非交互用法示例：`make release ARGS="--type app --version 1.0.7 --yes"`，或 `make release ARGS="--type plugin --version 1.0.10 --plugin-mode selected --plugin calendar --yes"`。
- 预览将执行的步骤可追加 `--dry-run`；正式发布前工作区必须干净。
- 本地发布前复制 `scripts/release.local.env.sample` 为 `scripts/release.local.env`，至少填写 `DEVELOPER_ID_APPLICATION`。
- 如需 Apple 公证，首次使用 `xcrun notarytool store-credentials` 保存凭证。
- 版本号默认读取 `project.yml` 中的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
- 生成本地正式包仍可使用底层脚本：`./scripts/release-local.sh`；发布到 GitHub Release 前需先完成 `gh auth login`，再执行 `./scripts/release-local.sh --publish`。
- 插件库发布使用 `plugins-*` 批次 tag 触发 `Plugin Release` workflow。默认只构建和上传版本递增的插件，并将新条目合并进生产 catalog；catalog 私钥、Developer ID 证书和 GitHub token 必须来自 CI secrets 或本地环境变量。
- GitHub Actions 自动构建与发布配置见 `docs/github-actions.md`；插件 catalog、包结构和批次发布流程见 `docs/plugins/plugin-catalog.md`。
