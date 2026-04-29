# Contributing to MacTools

感谢你关注 MacTools。请让每次贡献保持小而清晰：说明问题、给出可验证改动，并避免混入无关重构。

## 贡献方式
- Bug 报告请包含复现步骤、期望结果、实际结果、macOS 版本和相关日志或截图。
- 功能建议请说明使用场景、目标用户和预期交互；大型插件或交互变更请先开 issue 对齐范围。
- 涉及磁盘删除、系统权限、全局快捷键、显示器控制、签名或更新流程的改动，需要说明风险、保护措施和回滚方式。

## 开发环境
- 需要 Xcode 和 `xcodegen`，项目最低支持 macOS 14.0。
- 首次初始化：运行 `make setup`，再编辑 `LocalConfig.xcconfig` 填写 `DEVELOPMENT_TEAM` 和 `BUNDLE_IDENTIFIER_PREFIX`。
- 常用命令：`make generate` 生成 Xcode 项目，`make build` 编译校验，`make run` 本地运行。
- 不要提交本地或生成文件：`MacTools.xcodeproj`、`MacTools.xcworkspace`、`LocalConfig.xcconfig`、`build/`、`scripts/release.local.env`。

## 项目结构
- `Sources/App/`：应用入口、菜单栏状态项、设置页和窗口路由。
- `Sources/Core/`：插件宿主、快捷键、权限、日志、更新等共享基础能力。
- `Sources/Features/<Feature>/`：各功能插件和功能内模型、控制器、服务。
- `Tests/`：XCTest 测试，目录结构尽量镜像 `Sources/`。
- `project.yml`：XcodeGen 项目源文件；依赖和 target 变更应改这里。
- `docs/superpowers/`：较大的产品、交互或实施设计文档。

## 开发约定
- 新增菜单栏功能优先实现 `FeaturePlugin`；新增右键组件面板能力优先实现 `ComponentPlugin`。
- 插件展示状态通过 `PluginPanelState`、`PluginPanelDetail`、`PluginPanelControl` 等模型表达，不绕过现有面板框架。
- 插件状态变化后调用 `onStateChange?()`；耗时扫描、文件系统和系统调用不要长时间阻塞主线程。
- 用户可见文案以中文为主，保持简洁、清楚、接近 macOS 原生表达。
- 优先复用 Apple 原生框架；新增第三方依赖需说明理由并更新 `project.yml`。

## 测试
- 行为改动应补充或更新相邻 XCTest，测试文件命名使用 `<TypeName>Tests.swift`。
- 完整测试：`xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet`。
- 单个测试类：在完整测试命令后追加 `-only-testing:MacToolsTests/<TestClassName>`。
- 文件系统测试使用临时目录或 fake store；磁盘清理相关测试不得删除真实用户目录。

## Pull Request Checklist
- PR 范围聚焦，并说明变更目的、验证方式和用户影响。
- 构建或测试已通过；如无法运行，请在 PR 中说明原因。
- 用户可见行为变化已同步更新 `README.md` 或相关设计文档。
- 高风险功能已覆盖安全校验、错误状态和权限不足场景。
- 不包含无关格式化、生成物、本地配置、证书或发布凭证。

## Release
- 发布由维护者执行；不要在普通贡献中创建 tag、发布 GitHub Release 或提交发布产物。
- 本地发布前复制 `scripts/release.local.env.sample` 为 `scripts/release.local.env`，至少填写 `DEVELOPER_ID_APPLICATION`。
- 如需 Apple 公证，首次使用 `xcrun notarytool store-credentials` 保存凭证。
- 版本号默认读取 `project.yml` 中的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
- 生成本地正式包：`./scripts/release-local.sh`；发布到 GitHub Release 前需先完成 `gh auth login`，再执行 `./scripts/release-local.sh --publish`。
