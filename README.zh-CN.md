<div align="center">
  <img src="docs/assets/logo-mactools-rounded.png" width="96" height="96" alt="MacTools logo">
  <h1>免费开源的 macOS 原生菜单栏工具集合</h1>
  <p><strong>A free and open-source collection of native macOS menu bar tools</strong></p>
  <p>[中文] <a href="README.md">[English]</a></p>

  <p>
    <a href="https://github.com/ggbond268/MacTools/stargazers"><img src="https://img.shields.io/github/stars/ggbond268/MacTools?style=social" alt="GitHub stars"></a>
    <a href="https://github.com/ggbond268/MacTools/blob/main/LICENSE"><img src="https://img.shields.io/github/license/ggbond268/MacTools" alt="License"></a>
    <a href="https://github.com/ggbond268/MacTools/releases"><img src="https://img.shields.io/github/v/release/ggbond268/MacTools" alt="Latest release"></a>
    <a href="https://hellogithub.com/repository/ggbond268/MacTools" target="_blank"><img src="https://abroad.hellogithub.com/v1/widgets/recommend.svg?rid=6cddbd75f09848fb8848b58510394a5c&claim_uid=g4n28zqFcD0Vhw3&theme=small" alt="Featured｜HelloGitHub" /></a>
  </p>

  <p>聚合高频系统能力，保持轻量、快速、低打扰。使用 SwiftUI + AppKit 构建，支持 macOS 14.0 及以上版本。</p>
</div>

## 截图

<img src="docs/assets/screenshots/readme-hero-zh-dark.png" alt="MacTools 深色模式菜单栏面板">

## 功能

| 功能             | 说明                                                                                                                      |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------- |
| 显示器分辨率     | 查看已连接显示器，并按显示器切换可用分辨率。                                                                              |
| 显示器亮度       | 快速调节内建屏、DDC/CI 外接屏亮度，快捷键可跟随鼠标或同步控制所有显示器，并提供 Gamma/Shade 回退。                                   |
| 原彩显示         | 自动调节显示器颜色以适应环境光，支持 MacBook 和兼容显示器。                                                               |
| 显示器休眠       | 一键让所有显示器立即进入休眠，移动鼠标或按键可唤醒。                                                                      |
| 深色模式         | 一键切换系统亮色与深色外观，并实时跟随系统主题变化同步状态。                                                              |
| 夜览             | 一键开关 Night Shift，降低屏幕蓝光，使颜色偏暖，保护夜间视力。                                                            |
| 阻止休眠         | 保持系统空闲时唤醒，可在插件设置中默认启用屏幕常亮并显示会话状态标识，支持 30 分钟、1 小时、2 小时、5 小时后自动停止。              |
| 清洁模式         | 全屏黑色覆盖并临时禁用输入，适合清洁屏幕、键盘或触控板。                                                                  |
| 鼠标增强         | 增强鼠标与触控板控制，支持分别设置鼠标和触控板的水平/垂直滚动翻转，并可用触控板轻点模拟鼠标中键。                         |
| 隐藏刘海         | 自动遮挡内建刘海屏顶部区域，不修改用户原始壁纸。                                                                          |
| 隐藏菜单栏图标   | 通过菜单栏分割符隐藏左侧图标，支持拖动调整显示、隐藏与永久隐藏区域。                                                      |
| 自动隐藏菜单栏   | 自动隐藏菜单栏，提供更完整的屏幕显示空间。                                                                                |
| 自动隐藏程序坞   | 自动隐藏程序坞，提供更干净的桌面环境。                                                                                    |
| 台前调度         | 开启台前调度，集中显示当前窗口并把其他窗口收纳到侧边。                                                                    |
| 系统静音         | 一键静音或恢复系统音频输出，通过 CoreAudio 直接控制默认输出设备，停用插件时自动恢复。                                     |
| 麦克风静音       | 一键静音或恢复默认麦克风输入，通过 CoreAudio 直接控制输入设备，无需录音权限。                                             |
| 磁盘清理         | 扫描缓存、开发者缓存与浏览器缓存，执行前进行路径安全和敏感数据保护校验。                                                  |
| Xcode 清理       | 分类扫描 DerivedData、设备支持、归档、模拟器与预览缓存，Xcode 运行时自动禁用，仅在白名单根目录下执行删除。                |
| 推出磁盘         | 一键推出所有可移动磁盘，自动过滤系统卷并在无可推出磁盘时给出状态提示。                                                    |
| 清空废纸篓       | 显示废纸篓项目数，一键通过 Finder 清空，废纸篓为空时自动禁用按钮。                                                        |
| 清空剪贴板       | 一键清空当前剪贴板内容，保护隐私，防止误粘贴。                                                                            |
| IP 检测          | 查看国内/国际出口 IP、本地局域网 IP、归属地、运营商、ASN 与 macOS 网络测速，并支持复制单项或完整检测结果。                |
| 翻译             | 按全局快捷键翻译当前选中文本，第一版支持 OpenAI-compatible 服务与自动语言选择。                                          |
| 应用快捷键       | 为常用应用绑定全局快捷键，按下即可打开或将应用切换到前台；若应用已在前台则隐藏。                                          |
| 启动台           | 全屏或紧凑窗口唤出应用网格，支持即时搜索、横向分页、键盘导航、拖拽叠放建夹与文件夹改名（点开夹标题直接编辑，右键可重命名/解散），可调标签外观（颜色自动/白/黑/强调色、字重、随图标协调缩放的字号档，应用名称与文件夹标题共用），并对中文/日文输入法组字安全。 |
| 右键工具         | 为 Finder 右键菜单添加新建文件夹，以及复制文件名、绝对路径和相对路径。                                                    |
| 锁定屏幕         | 一键立即锁定屏幕，进入密码解锁界面，等同于 Cmd+Ctrl+Q 快捷键。                                                            |
| 启动项管理       | 可视化查看 LaunchAgent/LaunchDaemon，支持搜索筛选、字段解释和用户级启动项启停管理。                                       |
| 日历组件         | 在组件面板中查看月历、农历、节假日与当天日程。                                                                            |
| 系统状态         | 展示 CPU、GPU、内存、磁盘、网络、电量与高占用进程的近 1 小时图表。                                                        |
| 活动统计         | 统计键盘、鼠标、滚动、前台应用使用时长，并可通过手动 Hook 记录 Claude Code、Cursor、Codex 活动。                          |
| 设备电量         | 聚合 Mac、通过 USB 或 Wi-Fi 连接的已信任 iPhone/iPad/Apple Watch、蓝牙外设、AirPods 分体电量和雷柏 VT 系列鼠标电量，支持多种组件布局和可选低电量通知。                            |
| 风扇控制         | 通过预设管理风扇转速，支持自动、全速与自定义固定转速，实时显示当前转速；首次控制时会安装内置组件并请求管理员授权。          |
| 电池充电上限     | 限制电池充电至指定上限（默认 80%），达到上限后停止充电；电量低于上限时不自动恢复，由用户决定何时继续充电或强制放电。      |
| 修复损坏应用     | 移除应用隔离属性，解决「已损坏，无法打开」提示，通过文件面板选择 .app 并以管理员权限执行修复。                            |
| 退出应用         | 选择并退出正在运行的应用，或一键退出全部；支持反选，方便快速圈定目标。                                                    |
| zsh 配置         | 在应用内直接查看和编辑 zsh 配置文件（.zshrc、.zshenv 等），支持语法高亮、常用片段快速插入和保存前自动备份。               |
| 插件与设置       | 在插件市场中安装、更新和批量更新插件（支持分类/搜索筛选；可按未安装优先、已安装优先或按所选语言的名称排序），并在各插件设置页维护权限、快捷键和专属设置。                                |
| 状态栏图标自定义 | 上传本地图片或轻量 GIF/MP4 动画作为菜单栏图标，也可从在线图库按需下载动态图标，并支持自动扣背景、播放速度调整和恢复默认。 |
| 多语言           | 默认跟随系统语言，也可在「设置 > 通用 > 外观」中固定应用语言；语言选择器会同时显示系统语言名称和语言本名。                |

> **右键功能：** 可以使用 Option + 左键点击 MacTools 图标触发右键功能。

## 支持语言

MacTools 支持简体中文、繁體中文、English、Español、Français、Русский、Português、Deutsch、日本語、한국어和 العربية。

## 安装

```bash
brew install --cask mactools
```

## 升级

```bash
brew update
brew upgrade --cask --greedy mactools
```

如果仍提示已经是最新版本，可以先查看本地识别到的 cask 版本：

```bash
brew info --cask mactools
```

## 参与贡献

开发环境、测试、插件开发和发布流程请参考 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)。

## 许可证

MacTools 基于 [Apache License 2.0](LICENSE) 开源。

## 致谢

- 第三方素材、依赖与实现参考见 [Sources/Resources/ThirdPartyNotices](Sources/Resources/ThirdPartyNotices)。
- 贡献者

  <a href="https://github.com/ggbond268/MacTools/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=ggbond268/MacTools&max=120&columns=12" width="480" alt="contributors">
  </a>
