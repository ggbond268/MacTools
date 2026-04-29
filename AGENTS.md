# Agent Instructions for MacTools

## 指令范围
- 本文件是本仓库的 canonical agent 指南，适用于整个仓库。
- 若子目录未来出现更近的 `AGENTS.md`，以更近文件为准。
- `CLAUDE.md`、`GEMINI.md` 只做兼容入口；共享规则应优先维护在本文件。

## 项目概览
- MacTools 是原生 macOS 菜单栏工具集合，面向高频、轻量、不打扰的系统能力。
- 技术栈为 Swift 6、SwiftUI + AppKit，最低支持 macOS 14.0。
- 功能以插件组织：物理清洁模式、磁盘清理、阻止休眠、隐藏刘海、显示器亮度、显示器分辨率、系统状态、日历组件。
- 用户可见文案当前以中文为主；新增文案需保持简洁、清楚、接近 macOS 原生表达。

## 关键目录
- `Sources/App/`：应用入口、菜单栏状态项、面板、设置页和窗口路由。
- `Sources/Core/Plugins/`：插件协议、插件宿主、展示偏好和插件通用模型。
- `Sources/Core/Shortcuts/`：全局快捷键模型、存储和管理。
- `Sources/Core/Permissions/`：系统权限检查。
- `Sources/Core/Diagnostics/`：统一日志入口。
- `Sources/Core/Updates/`：Sparkle 更新检查与关于页更新状态。
- `Sources/Features/<Feature>/`：各功能插件和功能内模型、控制器、服务。
- `Tests/`：XCTest 测试，目录结构尽量镜像 `Sources/`。
- `Configs/`：Xcode build settings 与 `Info.plist`。
- `docs/superpowers/`：较大的产品/交互设计规格与实施计划。
- `scripts/`：发布、签名、公证和 GitHub Release 辅助脚本。

## 构建与运行
- 先运行 `make setup` 初始化 `LocalConfig.xcconfig`，再填写 `DEVELOPMENT_TEAM` 与 `BUNDLE_IDENTIFIER_PREFIX`。
- `project.yml` 是 XcodeGen 的项目源文件；`MacTools.xcodeproj` 是生成物，默认不提交。
- 生成项目：`make generate` 或 `xcodegen generate`。
- 编译校验：`make build`。
- 本地运行：`make run`。
- 运行完整测试：`xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet`。
- 运行单个测试类：在完整测试命令后加 `-only-testing:MacToolsTests/<TestClassName>`。
- 只在需要发布时使用 `./scripts/release-local.sh`；签名、公证、发布和打 tag 前必须确认用户意图。

## 架构约定
- 新增菜单栏功能优先实现 `FeaturePlugin`，新增右键组件面板能力优先实现 `ComponentPlugin`。
- `PluginHost` 负责插件注册、排序、可见性、快捷键、权限卡片和派生展示状态；不要让具体插件直接操纵宿主 UI。
- 插件 UI 应通过 `PluginPanelState`、`PluginPanelDetail`、`PluginPanelControl` 等描述式模型表达；除 `ComponentPlugin.makeComponentView` 外，避免绕过现有面板框架自建菜单栏 UI。
- 插件状态与 UI 相关代码默认在 `@MainActor`；耗时扫描、文件系统或系统调用应避免长时间阻塞主线程。
- 插件状态变化后调用 `onStateChange?()`，使宿主重建派生状态。
- 控件 ID、插件 ID、快捷键 ID 要稳定、可读，并尽量集中在功能内的私有常量中。
- 新增插件需在 `PluginHost` 的默认 `plugins` 或 `componentPlugins` 列表中注册，并设置合适的 `order`。

## Swift 代码风格
- 保持现有 Swift 风格：小类型、明确命名、早返回、少全局状态。
- 优先使用 Apple 原生框架；引入第三方依赖前先说明理由并更新 `project.yml`。
- 使用 `AppLog` 添加 OSLog category，避免在应用代码中使用裸 `print`。
- 与 AppKit、CoreGraphics、IOKit、EventKit 等系统 API 交互时，保留失败分支和降级路径。
- 文件、路径、权限、显示器 ID、快捷键绑定等外部输入必须校验后再使用。
- 不要把签名证书、notary 凭证、bundle 前缀、开发团队 ID 等本地敏感配置写入仓库。

## 功能安全边界
- 磁盘清理：不得绕过 `DiskCleanSafetyPolicy`、白名单、敏感路径保护和执行前二次校验；扩大清理范围必须补测试。
- 物理清洁模式：必须保留可退出路径、辅助功能权限引导、多屏覆盖和睡眠/锁屏后的安全退出逻辑。
- 隐藏刘海：不要破坏用户原始壁纸；注意多显示器、Space 切换和壁纸变化场景。
- 显示器亮度：优先保留 Apple 原生、DDC/CI、Gamma/Shade 回退链路，外接屏失败时不要崩溃。
- 显示器分辨率：切换前确认显示器仍连接且目标模式仍存在；错误应转为用户可理解状态。
- 日历：不要假设权限已授予；权限不足时应提供清楚引导而非静默失败。
- 更新发布：Sparkle appcast、版本号、签名和公证相关改动要小心，避免提交本地发布产物。

## 测试要求
- 行为改动优先补或更新相邻 XCTest；测试文件命名使用 `<TypeName>Tests.swift`。
- 新增功能测试放在 `Tests/Features/<Feature>/`，核心逻辑测试放在 `Tests/Core/` 对应目录。
- 文件系统测试使用临时目录或 fake store，禁止删除真实用户目录。
- 插件交互测试应覆盖 `PluginPanelAction`、派生 `PluginPanelState`、权限状态和错误状态。
- 无法运行测试时，在最终回复中明确说明原因和建议的本地验证命令。

## 文档与资源
- 用户可见功能变化需同步更新 `README.md`。
- 大型产品/交互变更可在 `docs/superpowers/specs/` 或 `docs/superpowers/plans/` 添加日期前缀文档。
- 图标、asset catalog、`LocalConfig.xcconfig`、发布 env 文件通常由用户或生成流程维护；不要无关改动。

## Agent 工作流
- 开始修改前用 `rg`/`rg --files` 快速定位现有模式，优先复用相邻实现。
- 保持改动聚焦，不顺手重构无关模块，不覆盖用户已有改动。
- 修改 `project.yml` 后运行或建议运行 `make generate`。
- 验证从最小相关测试开始，再视情况运行完整测试或 `make build`。
- 不要自动 commit、创建分支、打 tag、发布 release 或清理用户文件，除非用户明确要求。
