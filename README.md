# MacTools

MacTools 是一款原生 macOS 菜单栏工具集合，聚焦高频、轻量、不打扰的系统能力。当前内置物理清洁模式、阻止休眠与显示器分辨率控制插件，并提供统一的快捷键、功能管理与应用更新体验。

## Product

### Overview

- 菜单栏常驻，默认不进入 Dock，适合日常后台使用。
- 基于插件化功能面板组织能力，支持按需启用、隐藏与排序。
- 菜单栏面板支持分层详情交互，可在主面板中选择功能，并在侧边详情面板中完成更细粒度的操作。
- 使用 SwiftUI + AppKit 构建，保持接近 macOS 原生交互与视觉风格。
- 支持 macOS 14.0 及以上版本。

### Built-in Plugins

| 插件 | 说明 | 关键能力 |
| --- | --- | --- |
| 物理清洁模式 | 在全部显示器上覆盖黑屏层，并临时禁用输入事件，适合清洁屏幕、键盘或触控板时避免误触与误操作。 | 多屏覆盖、退出快捷键水印、辅助功能权限校验、锁屏或睡眠后自动退出 |
| 阻止休眠 | 通过系统级空闲休眠断言保持 Mac 处于唤醒状态，同时允许显示器按照系统策略正常息屏，适合下载、远程连接或长时间后台任务。 | 常驻保持唤醒、30 分钟/1 小时/2 小时/5 小时自动停止 |
| 显示器分辨率 | 在菜单栏中查看已连接显示器，并为每台显示器切换可用分辨率，适合外接显示器、多屏办公或临时调整显示精细度。 | 按显示器分组浏览、显示当前分辨率、仅展示当前纵横比下的可用模式、侧边详情面板快速切换 |

### Key Capabilities

- 快捷键管理：支持为动作配置快捷键，必要快捷键可重置但不可删除。
- 功能管理：支持插件显示或隐藏，并支持顺序调整。
- 菜单栏二级面板：支持导航列表与侧边详情联动，适合承载显示器分辨率这类多层级功能。
- 应用更新：关于页内置版本信息与更新检查能力，并对磁盘镜像、系统隔离目录等不可更新场景提供明确提示。
- 原生设置页：集中管理权限状态、功能入口、快捷键与应用信息。

## Development & Release

### Requirements

- Xcode
- `xcodegen`

### Quick Start

1. 运行 `make setup` 初始化本地配置和项目基础环境。
2. 编辑 `LocalConfig.xcconfig`，填写 `DEVELOPMENT_TEAM` 和 `BUNDLE_IDENTIFIER_PREFIX`。
3. 本地开发使用 `make run`，如只需编译校验可执行 `make build`。

### Release

1. 复制 `scripts/release.local.env.sample` 为 `scripts/release.local.env`，至少填写 `DEVELOPER_ID_APPLICATION`。
2. 如需 Apple 公证，首次执行一次 `xcrun notarytool store-credentials` 保存凭证，后续可直接复用。
3. 版本号默认读取 `project.yml` 中的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
4. 生成本地正式包：

```sh
./scripts/release-local.sh
```

5. 如需同步到 GitHub Release，先完成 `gh auth login`，再执行：

```sh
./scripts/release-local.sh --publish
```

更多参数可通过 `./scripts/release-local.sh --help` 查看。
