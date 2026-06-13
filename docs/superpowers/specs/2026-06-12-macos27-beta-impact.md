# macOS 27 beta（26A5353q）对 MacTools 的影响审计 + 官方变更研究 —— 2026-06-12

## A. 官方变更研究（deep-research，核心 finding 均 3-0 对抗验证通过）

**最重要发现：macOS 27 有官方新 API**——`NSStatusItem.expandedInterfaceDelegate` / `expandedInterfaceSession` / `NSStatusItemExpandedInterfaceSession` 类 / `NSStatusItemExpandedInterfaceDelegate` 协议（WWDC26 Session 289「Modernize your AppKit app」）。官方定位：status item 显示临时自定义 UI/窗口时告知 AppKit，使键盘焦点行为正确。**且键盘导航中按 Return 自动触发 button 的 target/action**——这是我们 popover 适配的官方通道。

macOS 27 (Golden Gate, beta 1, WWDC 2026 周期) 对第三方菜单栏 app 的官方变更可以总结为「有新 API、无架构文档、无相关弃用、社区已证实剧变」。问题②答案为肯定：Apple 在 27.0 beta 新增官方 NSStatusItem「expanded interface session」API（expandedInterfaceDelegate/expandedInterfaceSession 属性、NSStatusItemExpandedInterfaceSession 类、NSStatusItemExpandedInterfaceDelegate 协议），由 WWDC26 Session 289 正式介绍，官方定位仅为「status item 显示临时自定义 UI 时让 AppKit 管理键盘焦点」，并新增菜单栏键盘导航行为（Return 触发 button target/action）。问题①答案为否定：所有官方渠道（macOS 27 beta release notes、AppKit updates 页、What's new in macOS 27 页、Session 289 全文）对「status items 合成进 WindowServer 单一窗口、button window 变假桩、mouseDown/右键不投递、CGWindowList 不可枚举」零记载——该架构重构目前仅有社区/同行开发者证据：BetterTouchTool 开发者 Hegenberg 于 2026-06-10 第一手证实「以前每个 status item 是独立小窗口，现在全部菜单栏项只由一个窗口表示」，并列出 Bartender/Barbee/Ice/Thaw/Sane Bar/Glow/BTT 全部失效（问题④）。问题③：release notes 的 Deprecations 仅四项（CoreStorage 加密 HFS+、Rosetta/Intel 软件 macOS 28 起停用、禁止直接访问 TCC 数据库、UIKit 强制 scene lifecycle），CGWindowListCopyWindowInfo、CGEventPost/event tap、CGSetDisplayTransferByTable/gamma、DDC/CI、SecStaticCode、Sparkle 全文零命中、均未被弃用。把新 API 与底层重构挂钩目前仍是社区推断，Apple 未给出任何架构层面的官方说明。

### 研究 findings（带出处与置信度）

- **[high] 【问题② — 官方确认】macOS 27.0 beta 新增官方 NSStatusItem「expanded interface session」API：NSStatusItem 上的 beta 属性 expandedInterfaceDelegate（weak, 可写）与只读 expandedInterfaceSession，新类 NSStatusItemExpandedInterfaceSession（含 cancel() 方法），新协议 NSStatusItemExpandedInterfaceDelegate 含且仅含两个 required 回调 statusItem(_:didBegin:) 与 statusItemDidEndExpandedInterfaceSession(_:animated:)（无任何鼠标事件回调）。WWDC26 Session 289「Modernize**
  出处: https://developer.apple.com/documentation/appkit/nsstatusitem; https://developer.apple.com/documentation/appkit/nsstatusitemexpandedinterfacedelegate; https://developer.apple.com/videos/play/wwdc2026/289/  (3-0（合并 4 条同主题 claim，各 3-0）)

- **[high] 【问题② — 官方确认】macOS 27 将系统级键盘导航扩展到菜单栏与第三方 status items：NSStatusItem.button 设有 target/action 时，键盘导航中按 Return 自动触发该 action；Apple 官方区分「点击显示菜单的 status item」（行为同菜单栏菜单）与「触发动作/显示临时 UI 的 status item」（后者需配合 expanded interface session API）。Session 289 专设章节「Keyboard navigation and status items」（5:51–8:57）。**
  出处: https://developer.apple.com/videos/play/wwdc2026/289/  (3-0)

- **[high] 【问题① — 官方零记载（负向发现）】研究问题①描述的菜单栏架构重构（status items 合成进 WindowServer 单一窗口、第三方 NSStatusItem button window 变假桩、mouseDown 不投递、右键不路由、CGWindowList 不可枚举 per-item 窗口）在全部官方渠道中零记载：(a) macOS 27 Golden Gate Beta Release Notes 全文（106KB JSON）对 'NSStatusItem'、'status item'、'status bar'、'WindowServer'、'CGWindowList'、'CGEvent'、'event tap'、'MenuBarExtra' 全部零命中，唯一菜单栏相关 AppKit 条目是菜单项图标显隐回退（NSMenuItem.preferredImageVisib**
  出处: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes; https://developer.apple.com/documentation/updates/appkit; https://developer.apple.com/macos/whats-new/  (3-0（合并 6 条负向发现 claim，各 3-0）)

- **[high] 【问题②补充 — 文档分布注意点】macOS 27 release notes 与官方概览页均未记载任何面向菜单栏 app 的新 API：release notes AppKit New Features 仅列 open/save panel 快捷键、NSRefreshController、NSToolbarItemGroup/NSSegmentedControl role、NSTextSelectionManager、NSMenuItem.preferredImageVisibility（唯一菜单相关新 API，仅控制图标显隐，UIKit 侧镜像为 UIMenuElement.preferredImageVisibility）；SwiftUI New Features 无 MenuBarExtra 任何增强。即：expanded interface session API 这一真实存在的**
  出处: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes; https://developer.apple.com/macos/whats-new/  (3-0（合并 3 条 claim）)

- **[high] 【问题③ — 官方确认（负向）】macOS 27 beta 1 release notes 的全部 Deprecations 小节只有四处：CoreStorage（加密 HFS+ 弃用, 175892420）、Rosetta（所有 Intel 软件 macOS 28.0 起不兼容、legacy games 除外, 176042635）、TCC（禁止直接访问本地 TCC 数据库, 90775556）、UIKit（最新 SDK 构建的 app 必须采用 scene-based lifecycle 否则无法启动, 141837548）。研究问题③关注的 CGWindowListCopyWindowInfo、CGEventPost/event tap、CGSetDisplayTransferByTable/gamma、DDC/CI、SecStaticCode、Sparkle/外部更新器在全文（含非**
  出处: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes  (3-0)

- **[high] 【问题④ — 同类工具开发者表态（社区一手，非 Apple 官方）】BetterTouchTool 开发者 Andreas Hegenberg 于 2026-06-10 在官方论坛发帖证实：macOS 27 Golden Gate beta 弄坏了绝大多数菜单栏管理 app，明确点名 Bartender、Barbee、Ice、Thaw、Sane Bar、Glow 及 BTT 自身菜单栏功能「all broke completely」；并给出第一手架构观察——「以前系统把每个 menu status item 报告为一个独立小窗口（第三方 app 可与之交互），现在所有菜单栏项只由一个窗口表示，这些菜单栏管理 app 赖以构建的整个架构都需要改」。这是研究问题①「status items 合成单一窗口 / per-item 窗口不可枚举」假设迄今最强的证据，但属同行开发者证实，非 Apple**
  出处: https://community.folivora.ai/t/macos-27-golden-gate-menu-bar-management-broken-solutions-ice-thaw-bartender-barbee-etc/47232; https://github.com/jordanbaird/Ice/issues/954  (3-0（合并 2 条 claim，各 3-0）)


---
## B. 全应用影响矩阵（探针实测 + 代码盘点）

| 组件 | 判定 | 详情 |
|------|------|------|
| 拖放/动作窗口锚定链（宿主 statusItemButtonFrameProvi | broken | 实锤：stub 按钮窗口（windowNumber=4294967296、零高 frame）下 Sources/App/MenuBarStatusItemController.swift:107-123 返回退化非 nil rect {{0,-11},{22,22}}，三个插件窗口分别落到 (8,-475)/(8,-555)/(8,-175) 屏幕外，borderless NSPanel 不会被系 |
| DisplayBrightness · Gamma 亮度回退链（含退出时还原） | broken | 实锤：CGGetDisplayTransferByTable 的 capacity=0 查表长惯用法在 26A5353q 返回 1001（两屏皆然），Plugins/DisplayBrightness/Sources/DisplayBrightnessBackends.swift:397,436 → canControl() 恒 false，gamma 一环整条静默失效，非 DDC 外接屏直接掉到 |
| DeviceBattery · 蓝牙外设电量（log show 通道，AirPo | broken | 实锤：beta 上 `log show --process X --predicate Y` 会丢弃 predicate（--process+predicate 4023 行 ≈ 无 predicate 4024 行；predicate 单独用=1 行）。Plugins/DeviceBattery/Sources/DeviceBatterySampler.swift:362-378 现在拿到 ~5 |
| 菜单栏面板交互链（popover 锚定到 stub 窗口 / 点图标关闭判定 / | 未测（高危，无法静默探针） | NSPopover 锚定 stub 几何可能错位（Sources/App/MenuBarPanelPresenter.swift:198-203，TODO 自认未修于 MenuBarStatusItemController.swift:323-331）；isEventInsideStatusButton 的 window 身份比较在 stub 下可能失败（:436-446）→ 点图标关不掉面板；全 |
| Translator · OCR 截图（CGDisplayCreateImage | degraded | 实锤三重：SDK 26.5 头文件已 obsoleted=15.0（仅因 deployment target 14.0 才编译过）；运行时符号仍在；语义已变——无效 displayID 0xDEADBEEF 返回非 nil 的 4288x1440 双屏 union 图像 → ScreenshotRegionCapturer.swift:84 的 .screenshotFailed nil-guar |
| MenuBarHidden · 事件合成面（右键转发 / Cmd+drag 移动 | broken（已 fail-closed，39a3ad4 已挡住） | beta 下 per-item 窗口不存在、右键不路由、Cmd+drag 语义全变，合成面本质不可用。当前由枚举层 gate fail-closed 拦住不会误发；残余风险：gate 在枚举层，若下个 beta 枚举返回似是而非数据会被重新放行并向错误坐标 post。隐藏/显示图标核心功能不受影响。 |
| DisplayBrightness · DDC 外接屏链路 | degraded（功能正常，结构单点化） | 端到端实测可用：IOAVService 创建成功、VCP 0x10 读到 Lenovo P27u-20 current=60 max=100。但 AppleCLCD2 服务在 beta 消失（count=0）、CGSServiceForDisplayNumber 对主屏返回 0（首选构造路径+framebuffer 兜底双死），匹配现在单点依赖 IOMobileFramebufferShim 名字 |
| MiddleClick · 三指中键 | 未测（符号层 ok） | 私有 MultitouchSupport dlopen 成功、9 符号全在、枚举到 1 台触控设备。未验证：MTDeviceStart 后触摸帧是否真到、结构体布局是否变（探针=监听用户输入，禁止）；菜单栏带上 down→otherMouseDown 改写后新合成窗口的路由未知，wasThreeDown 状态机可能因 up 不回流卡住。需上机三指实测。 |
| PhysicalCleanMode · 物理清洁模式 | 未测（进入路径 ok） | 过滤型 session tap 创建+启用实测正常（300ms 后仍 enabled）→ fail-closed 分支不会误触发。未验证：『拦截一切输入』在新事件管线下是否漏菜单栏/全局手势；退出快捷键依赖 tap callback 收到 keyDown。紧急退出逻辑（2 秒 3 次禁用即退）方向安全（fail-open）。副作用还原路径完整。 |
| BatteryChargeLimit / FanControl · SMC 写  | 未测写（读路径 ok） | AppleSMC selector-2 keyInfo 读全部正常（CHIE/F0Ac/FNum/F0Mn/F0Mx 在；CH0B/CH0C/BCLM/CH0I 是 Intel 键本机本就不存在，非回归）。写路径与 AppleScript admin 安装 helper 无法静默测；5 秒重断言循环+唤醒重断言提供自愈。上机各切换一次充电限制/风扇即可确认。 |
| 全局快捷键派发（GlobalShortcutManager / AppHotke | 未测派发（注册链全好） | Carbon GetEventDispatcherTarget/InstallEventHandler/Register/Unregister 全 noErr。历史教训（:75-77 注释）就是『注册成功但回调不触发』，beta 改事件路由后此风险升高；派发需真实按键无法静默验证——上机按一次已绑定快捷键即定论。 |
| NightShift / DisplayTrueColor（私有 CoreBri | 未测写（读 ABI 完整） | CBBlueLightClient 类在、三 selector 全响应、getBlueLightStatus 真实调用成功且字段自洽 → 读路径兼容。setEnabled/setStrength 写路径未测（会改系统状态），首次上机开关一次 Night Shift 即可。 |
| Translator · 划词翻译（合成 ⌘C） | 未测投递 | 创建半边实测正常（CGEventSource/CGEvent(keyboard)/flagsState 全 ok），post 到前台 app 是否到达无法静默验证（禁止合成）。失败路径完善（AX 前置拦截、剪贴板恢复）。上机划词翻译一次即定论。 |
| Sparkle 自动更新 | 未测安装（分发链全好） | appcast 抓取/解析正常（v1.0.18 minOS=14.0 可装 27.0、EdDSA 签名在、enclosure 200）；Sparkle.framework 在 beta dyld 下 dlopen 成功类齐全。残余：Autoupdate 安装器 XPC 与原子替换在 beta 安全策略下未走过——发版前手动走一次真实更新。 |
| 动态插件 · 本地手动安装路径（quarantine 链） | degraded（latent，一触即发） | 实测 ditto 把 zip 的 com.apple.quarantine 传播进解出的 bundle、copyItem/moveItem 保留 xattr，且插件包只 codesign 未公证 → 浏览器下载的 zip 走本地安装在 Release/hardened 宿主上 dlopen 必被 Gatekeeper 拒。当前 catalog 在线安装不触发（URLSession 下载无 xatt |
| DisplayResolution · 分辨率切换 | ok（commit 未测） | 模式枚举正常（136/132 个，废弃的 ioFlags/ioDisplayModeID 本 beta 仍返回有效值），begin+cancel 事务往返 .success。CGCompleteDisplayConfiguration(.permanently) 真切无法静默测；留意每屏各有 1 个 ioDisplayModeID==0 的模式理论撞车。下次用户主动切换时观察即可。 |
| HideNotch · 隐藏刘海 | ok（一处 watch 项） | SLS 私有 API schema 完整未变（2 屏、全键在、type 0/4 语义不变）、刘海几何正常（aux=771.5x32、safeArea.top=32）、遮罩层级数学成立（壁纸 -2147483625 < 遮罩 -2147483604 < 图标 -2147483603）。桌面层 tier 归属已被 Apple 重排（壁纸/WindowManager 下移、图标归 Finder）——方向 |
| 全屏覆盖窗 z 序（清洁模式遮罩 / Shade 亮度遮罩 / OCR 选区遮罩 | ok | 新 WindowServer 单一 Menubar 窗口在 layer 24，远低于 screenSaver(1000)，覆盖层仍能盖住菜单栏。注意 Shade 因 gamma 链死被迫从最后兜底升级为非 DDC 外接屏实际兜底，回归影响被放大——gamma 修复后回归。 |
| 动态插件运行链（信任校验 / catalog 签名 / 下载 / dlopen  | ok | SecStaticCode 全链行为不变（Developer ID team 提取正常、ad-hoc DEBUG 宽松路径正常）；Ed25519 catalog 签名 VALID → JSONSerialization 规范化未漂移（跨版本最脆点，每 seed 重验）；AMFI library validation 错误面经典未变；URLSession 下载无 quarantine。残余盲区：本机 |
| 系统状态类插件（SystemStatus / Calendar / EmptyT | ok | AppleSmartBattery 注册表键、SMC 温度读、IOPS 电源面、SCDynamicStore/getifaddrs/host_statistics、EventKit authorizationStatus（无新 @unknown case）、NSPasteboard 全部实测正常。EmptyTrash 的 Finder AppleScript 依赖 Automation 授权，be |
| 宿主杂项（主题切换通知 / 状态项排序 autosave / 登录启动 / 设置 | 未测×4 + ok | AppleInterfaceThemeChangedNotification 未文档化、触发需写系统设置不可探，需用户切一次外观验证；autosave position defaults 值正常但新宿主是否尊重排序需目测；SMAppService status 读正常，register 上机开关一次；cooperative activation 收紧与否开一次设置窗即知。ActivityBar：权 |

## C. 修复 backlog


### 立即修（小时级）
- **宿主锚点退化时 fail-closed 返回 nil（一处修复救 QuitApps/XcodeClean/FixDamagedApp 三插件）**
  入口: Sources/App/MenuBarStatusItemController.swift:107-123 — 在现有 DEGENERATE 诊断分支（height<=0 || isStubBackingWindow，检测函数已在 Sources/App/MenuBarStatusItemCompatibility.swift:25-41）改为 return nil，让三个插件的『anchor==nil → 屏幕中心』兜底真正可达。
- **Gamma 容量探测改用 CGDisplayGammaTableCapacity**
  入口: Plugins/DisplayBrightness/Sources/DisplayBrightnessBackends.swift:397,436 — 把 capacity=0+nil 缓冲查表长的两处惯用法换成 CGDisplayGammaTableCapacity(displayID)+按该容量读表（探针已证 cap=1024、读=.success），同时修复 canControl() 与 loadOriginalTransferTableIfNeeded。
- **DeviceBattery 去掉 --process 只留 --predicate**
  入口: Plugins/DeviceBattery/Sources/DeviceBatterySampler.swift:362-378 — 从 log show 参数删除 "--process","bluetoothd"（predicate 已含 subsystem==com.apple.bluetooth 可替代进程过滤；predicate 单独使用在 beta 被正常执行），消除 firehose+超时截断。
- **Translator stale displayID 防御**
  入口: Plugins/Translator/Sources/OCR/ScreenshotRegionCapturer.swift:84 — capture 前校验 displayID 仍在线（CGGetOnlineDisplayList 包含），并校验返回图像像素尺寸 ≈ CGDisplayBounds×scale，不匹配按 .screenshotFailed 处理（堵住 beta 下 nil-guard 已死的洞）。
- **make run 上机验证批次（探针约束无法覆盖的决定性项）**
  入口: 一次运行覆盖清单：popover 弹出位置/二级侧栏、点图标关闭+外点收起、按一次全局快捷键、三指中键、划词翻译、Night Shift 开关、修复后的 QuitApps 落点；顺带在用户活跃时重跑 probe_b/probe_g 定论全局 monitor 与菜单栏带投递。

### 适配修（天级）
- **popover stub 窗口锚定兼容**
  入口: Sources/App/MenuBarPanelPresenter.swift:198-203（TODO 自认于 MenuBarStatusItemController.swift:323-331）— 若上机证实错位：检测到 stub 时不再 show(relativeTo: button)，改用 statusItem 屏幕 rect 或 NSScreen 顶缘估算位置自定位（screen fallback :102,:138 已有半套）。
- **isEventInsideStatusButton 改几何判定**
  入口: Sources/App/MenuBarStatusItemController.swift:436-446 — 用按钮屏幕 rect（statusItemButtonScreenRect 修复后版本）contains NSEvent.mouseLocation 替代 event.window === button.window 身份比较，stub 下身份链不可信。
- **Translator OCR 迁移 ScreenCaptureKit**
  入口: Plugins/Translator/Sources/OCR/ScreenshotRegionCapturer.swift:60 — CGDisplayCreateImage SDK 已 obsoleted=15.0 且 beta 语义已变，displayImageProvider 迁 SCScreenshotManager（框架本机已确认存在）；min target 升 15 前必须完成否则编译失败。
- **Gamma 还原链与 Shade 回归**
  入口: Plugins/DisplayBrightness/Sources/DisplayBrightnessBackends.swift:361-388 — 随容量修复重建 originalTransferTable 加载并补 cleanup 还原测试（副作用必须可还原的安全边界）；人工验证 Shade 0%→100% 往返与多屏覆盖一次（:441-577）。
- **HideNotch notchHeight fallback 调整**
  入口: Plugins/HideNotch/Sources/HideNotchDisplayCatalog.swift:149-150 — 改为优先 aux 区高度（32pt），menuBarHeight 仅在 aux 缺失时参与 max()；beta 外接主屏菜单栏已实测 ~30pt，再涨即黑条溢出刘海区。
- **深浅色图标刷新加 KVO 兜底**
  入口: Sources/App/MenuBarStatusItemController.swift:185-193 — 在未文档化的 AppleInterfaceThemeChangedNotification 旁加 NSApp.effectiveAppearance KVO 兜底，通知改名/限发也不丢刷新。
- **本地插件安装路径 quarantine 检测**
  入口: Sources/Core/Plugins/Dynamic/Package/PluginPackageResolver.swift:300-327 — 安装前检测 com.apple.quarantine xattr 并剥离或给出明确错误（而非装好后 Release 宿主 dlopen 静默被 Gatekeeper 拒）；长期在 scripts/sign-plugin-package.sh 补 notarytool 公证。
- **MiddleClick 配对状态机防卡死**
  入口: Plugins/MiddleClick/Sources/MiddleClickSession.swift:86-128 — wasThreeDown 加超时复位/位置校验，防菜单栏带 down 被改写后 up 不回流，导致后续一次普通左键 up 被误改写成中键 up。

### standby（等 Apple / beta 2）
- **MenuBarHidden 事件合成面整体**
  入口: Plugins/MenuBarHidden/Sources/MenuBarHiddenEventSynthesis.swift:80-144 — 维持 39a3ad4 fail-closed；在枚举 gate 上加数据合理性二次校验（防下个 beta 返回似是而非数据被误放行），每个 seed 重跑窗口拓扑探针，等 Apple 给 per-item 窗口替代品或正式 API。
- **DDC 注册表 shim 单点依赖监控**
  入口: Plugins/DisplayBrightness/Sources/DisplayBrightnessDDC.swift:498-567 — 当前 IOMobileFramebufferShim 兜底可用不动代码；每 seed 重跑 probe4/probe7，shim 改名才适配；AppleCLCD2/CGSServiceForDisplayNumber 死路径（:1032,:498-530）等正式版确认永久死亡再清理。
- **log show predicate 被 --process 吞掉 → 提 Feedback**
  入口: 疑似 beta 自身 bug（predicate 单独用正常）——提交 Apple Feedback 附最小复现；我们已用立即修 #3 绕过，beta 2 验证恢复与否决定是否回退 --process 优化。
- **私有面巡检探针固化为脚本**
  入口: 把本轮探针收进 scripts/（CoreBrightness/MultitouchSupport/SkyLight schema/DisplayServices/IOAVService DDC 只读/gamma 容量/catalog Ed25519 规范化/窗口拓扑 layer 普查），每个新 seed 一键重跑——本轮全部高危私有面都属『当前活着但每 seed 必验』。
- **发版前真实链路演练**
  入口: 正式发版/beta 2 前手动走一次：Sparkle 真实更新（Autoupdate XPC+原子替换）、Release 签名宿主加载同 Team 动态插件（本机无 Release 宿主无法提前证明）、充电限制+风扇 SMC 写各切换一次。

## D. 探针原始结论

- [ok] carbon-hotkey-registration: GetEventDispatcherTarget non-nil=true; InstallEventHandler=0; RegisterEventHotKey(F15+all-mods)=0 ref non-nil; UnregisterEventHotKey=0. Carbon hotkey registration chain fully intact.
- [inconclusive] global-mouse-monitor-delivery: Ran the full 180s in background: installed=true, delivered=0, locChanges=0, systemSawMouseMove=false → no mouse activity in the entire window (machine unattended; CGEventSource rep
- [ok] ax-permission-and-smappservice: AXIsProcessTrusted=true; AXIsProcessTrustedWithOptions(prompt:false)=true (no prompt shown); SMAppService.mainApp.status raw=3 (.notFound, expected for a bare CLI process). All aut
- [ok] sparkle-appcast-chain: appcast 2051 bytes; v1.0.18 minOS=14.0 maxOS=None installable_on_27.0=True, edSignature present, enclosure HEAD 200 len=6096378. Update network/gating chain healthy for macOS 27.0.
- [ok] sparkle-framework-dyld-load: dlopen build-product Sparkle.framework OK; SPUUpdater/SPUStandardUpdaterController/SUAppcast/SUAppcastItem all FOUND. Sparkle loads under beta dyld/AMFI.
- [ok] secstaticcode-plugin-trust-chain: HideNotch.bundle: create=0 validity=0 signingInfo=0 team=nil (ad-hoc, DEBUG-lenient path normal); /System/Applications/Calculator.app: validity=0 (platform binary, no third-party t
- [ok] private-corebrightness-cbbluelightclient: dlopen CoreBrightness OK; CBBlueLightClient FOUND; getBlueLightStatus/setEnabled/setStrength:commit: all respond; live getBlueLightStatus=1 available=1 enabled=0 mode=0 (read only;
- [ok] private-multitouchsupport-symbols: dlopen MultitouchSupport OK; all 9 symbols (MTDeviceCreateList/CreateDefault/IsAlive/IsRunning/Register+UnregisterContactFrameCallback/Start/Stop/Release) present; MTDeviceCreateLi
- [ok] display-reconfig-and-nsscreen: Register/Remove reconfiguration callback both .success(0); NSScreen.screens=2, NSScreen.main non-nil (built-in display 1 @1728x1117, external display 4 @2560x1440). The popover-fal
- [ok] load-monitor-stats-keys: IOServiceGetMatchingServices(IOAccelerator)=KERN_SUCCESS; PerformanceStatistics present with watched keys [Device Utilization %, Renderer Utilization %, Tiler Utilization %] (3/4; 
- [ok] probe1_private_symbols: All 10 DisplayServices/SkyLight/CoreDisplay symbols FOUND. CoreDisplay_DisplayCreateInfoDictionary(main) keys complete (IODisplayLocation=.../dispext0/IOMobileFramebufferShim, Disp
- [ok] probe2_sls_managed_display_spaces: SLSDefaultConnectionForThread=2522379; SLSCopyManagedDisplaySpaces returns 2 displays; 'Display Identifier'/'Current Space'/'Spaces'/uuid/type keys all intact; built-in display car
- [broken] probe3_modes_gamma_configtxn_reconfig: Gamma size-query idiom CONFIRMED broken: CGGetDisplayTransferByTable(id,0,nil,nil,nil,&count)=1001 on both displays (supplemental run on online IDs 4 & 1) → GammaBrightnessBackend.
- [broken] probe6_gamma_regression_isolation: Regression isolated on online display IDs (active list empty due to sleep): ByTable capacity=0 size-query=1001 (FAILS) on both displays, while ByTable(4096 buffer)=0 got=1024 and B
- [ok] probe9_gamma_capacity_fixpath: Fix-path viable: CGDisplayGammaTableCapacity=1024 on both displays, and CGGetDisplayTransferByTable(id, cap=1024, ...)=0 got=1024 succeeds. Switching canControl()/loadOriginalTrans
- [degraded] probe4_iokit_ddc_registry: AppleCLCD2 count=0 (gone on beta → nearbyDisplayProperties' preferred service name落空; IOMobileFramebufferShim count=5 fallback present). DCPAVServiceProxy count=1 (External only, p
- [ok] probe7_ddc_endtoend_readonly: DDC backend fully functional: IOMobileFramebufferShim dispext0 carries DisplayAttributes + ProductName=P27u-20 + EDID UUID 30AECB62; IOAVServiceCreateWithService(external)=OK; stan
- [ok] probe5_notch_geometry_window_tiers: Built-in display: auxTopLeft/Right=771.5x32pt, safeAreaInsets.top=32 (notch geometry intact); external P27u-20: aux=nil/top=0 (no notch). Mask-level math holds: desktopWindow=-2147
- [ok] probe_a_permissions_hid（权限状态位 + HID 免 open 枚举）: AXIsProcessTrusted=true; IOHIDCheckAccess listen=granted post=granted; CGPreflightListenEventAccess=true; CGPreflightPostEventAccess=true; IOHIDManagerCopyDevices=23, vendorUsagePa
- [inconclusive] probe_b_listen_tap_census（listenOnly session tap 创建 + 4 秒被动投递普查）: tapCreate(.listenOnly,.cgSessionEventTap)=ok, tapIsEnabled=true. 4s window saw zero events (machine unattended/idle), so session-tap delivery + menu-bar-band down/up/drag counts ar
- [ok] probe_c_filter_tap（defaultTap 过滤型 tap 创建——PhysicalClean 进入路径）: tapCreate(.defaultTap,.headInsert,.cgSessionEventTap) with full event mask=ok; tapEnable=true and stillEnabledAfter300ms=true (callback pure passthrough). PhysicalCleanMode's event
- [ok] probe_d_multitouch（私有 MultitouchSupport 框架存活检查）: dlopen=ok; missingSymbols=none (MTDeviceCreateList/Register/Unregister/Start/Stop/Release all present); MTDeviceCreateList count=1. MiddleClick's private framework survives 26A5353
- [ok] probe_e_carbon_hotkey（Carbon 热键注册/注销路径）: RegisterEventHotKey(Ctrl+Opt+Cmd+Shift+F18)=0; UnregisterEventHotKey=0; InstallEventHandler(GetEventDispatcherTarget)=0. Registration path healthy (handler dispatch on real keypres
- [ok] probe_f_eventsource_state（CGEventSource 只读状态 + 事件创建不投递）: secondsSince mouseMoved=1451.3 scroll=1452.8 keyDown=1446.5 (confirms ~24min idle); flagsState=256; buttonState(left)=false; CGEventSource(.hidSystemState)=ok; CGEvent(keyboard) ke
- [inconclusive] probe_g_nsevent_global_census（NSEvent 全局 monitor 被动普查，6 秒）: monitorsInstalled=3/3 (leftMouseDown/Dragged/Up). 6s window: global downs/drags/ups all 0 and menu-bar-band all 0 — machine idle, no clicks. Installation healthy; the key unknown (
- [ok] iokit-service-names-and-iops: AppleSMC/AppleSmartBattery/IOAccelerator/AppleMultitouchDevice all FOUND; IOPS=1 InternalBattery cap=100 state='AC Power'; external adapter dict full (11 keys incl Watts/AdapterPow
- [ok] eventkit-authstatus-readonly: EKEventStore.authorizationStatus(.event) raw=0 mapped=notDetermined; no @unknown new case. Read-only, no prompt.
- [ok] smc-keyinfo-readonly: IOServiceOpen(AppleSMC) + selector-2 cmd-9 keyInfo works: all 10 keys return r=0x0 (success). Existing-on-this-HW keys report sizes (CHIE=1, F0Ac=4, FNum=1, F0Mn=4, F0Mx=4); Intel-
- [broken] log-predicate-dropped-when-process-set: CONFIRMED regression: `log show --process bluetoothd --last 3m` = 4024 lines vs same with `--predicate category==CBPowerSource` = 4023 lines (≈equal → predicate IGNORED when --proc
- [ok] bluetooth-and-hid-resolve: AppleDeviceManagementHIDEventService=1 (DeviceBattery IORegistry source present); other HID classes 0; IOBluetoothDevice.pairedDevices()=13; system_profiler SPBluetoothDataType JSO
- [ok] netconfig-host-pasteboard-volume: SCDynamicStore Global/IPv4 PrimaryInterface=en0; getifaddrs=47; host_statistics=0; NSPasteboard changeCount=1629 items=1; volume total=994610155520. Low-risk public surface normal.
- [ok] probe_window_topology: 43 onscreen windows enumerable; windows at status layer 25 = 0 (pre-27 had one per NSStatusItem — confirms menu-bar extras are no longer per-item windows); the only menu-bar-tier w
- [broken] probe_dropzone_anchor_degradation: CONFIRMED: host trace shows buttonScreenRect DEGENERATE rect={{0,-11},{22,22}} windowNumber=4294967296 stub=true (provider returns a degenerate NON-NIL anchor instead of failing cl
- [ok] probe_sls_managed_display_spaces_schema: SLSCopyManagedDisplaySpaces symbol present; payload = 2 displays; 'Display Identifier'/'Current Space'/'Spaces'/uuid/type keys all intact; type 0 (normal) / type 4 (fullscreen) sem
- [degraded] probe_displaycapture_api_viability: This run (no-screenshot constraint respected): CGPreflightScreenCaptureAccess=true (no prompt); CGDisplayCreateImage/ForRect, CGWindowListCreateImage, CGRequestScreenCaptureAccess 
- [ok] probe1-seccode-chain: Calendar.bundle: validity=0 team=nil format='bundle with Mach-O thin (arm64)'; MacTools Dev.app: validity=0 team=nil; Calculator.app: validity=0 (platform); Clash Verge.app: validi
- [ok] probe2-bundle-load: Target bundle non-quarantine (verified). Bundle(url:) id=com.example.mactools.plugins.calendar; bundle.load()=success (dyld/AMFI accept the ad-hoc bundle in a non-hardened CLI proc
- [ok] probe3-ditto-quarantine-propagation: Behavior unchanged from baseline (not a beta regression): ditto -x -k --sequesterRsrc --rsrc PROPAGATES com.apple.quarantine from a quarantined zip to the extracted plugin.json (xa
- [ok] probe4-catalog-signature-and-download-xattr: catalog GET=200 (41664 bytes); canonical payload 31245 bytes; Ed25519 signature VALID → JSONSerialization(.sortedKeys,.withoutEscapingSlashes) canonicalization has NOT drifted on t
- [ok] probe5-library-validation-surface: Hardened ad-hoc binary (codesign flags=0x10002 adhoc,runtime) loading the ad-hoc plugin bundle FAILS as expected: NSCocoaErrorDomain Code=3588, dlerror 'mapping process and mapped 

## E. 给用户的现状报告
## macOS 27.0 beta (26A5353q) 影响面审计现状报告

6 个家族（宿主核心/显示器/输入事件/系统状态/窗口枚举/插件链）共盘点约 80 个系统 API 触点，39 个静默探针实测完毕。结论先行：**新发现 3 个实锤损坏 + 1 个语义退化**，已有修复路径全部验证可行；私有 API 面（CoreBrightness、MultitouchSupport、SkyLight、DDC）本 seed 意外地全部存活。

### 已确认坏了（探针实锤，待修）
1. **QuitApps / XcodeClean / FixDamagedApp 三个插件的弹窗全部落到屏幕外**——宿主把 stub 状态项窗口换算出的退化坐标原样返回，点功能后表现为"没反应"。一处宿主修复（退化时返回 nil）即救三个插件，小时级。
2. **亮度 Gamma 回退链整条静默失效**——CGGetDisplayTransferByTable 的查表长惯用法在本 beta 回归（返回 1001），非 DDC 外接屏被迫掉到 Shade 遮罩，且退出时的 gamma 还原链同断。换 CGDisplayGammaTableCapacity 即修，探针已验证可行。
3. **蓝牙外设电量（AirPods/鼠标）随机缺失 + 刷新时 CPU 尖峰**——beta 的 `log show` 在 `--process` 与 `--predicate` 同用时丢弃 predicate，DeviceBattery 拿到每分钟几十万行的 firehose。删掉 `--process` 即修（顺带给 Apple 提 Feedback）。
4. **OCR 截图错误路径已死**——CGDisplayCreateImage 对无效显示器 ID 不再返回 nil 而是返回全桌面拼接图，热拔显示器后划词 OCR 可能静默识别错误区域。先加在线校验堵洞，中期迁 ScreenCaptureKit（该 API 已被 SDK 标记废弃）。

### 之前已修好的（背景）
菜单栏状态项合成进 WindowServer 单一窗口的核心冲击（点击路由、右键、MenuBarHidden 枚举）已由 commit 39a3ad4 做了兼容/fail-closed，本轮探针确认 gate 仍正确生效；MenuBarHidden 的图标隐藏/显示核心功能可用，只有移动图标/点击转发这类合成功能被安全禁用，等后续 beta。

### 实测还能正常用的
DDC 外接屏亮度（端到端读通，虽然内部匹配路径单点化了）、内建屏原生亮度、隐藏刘海（私有 SLS schema 完整、遮罩层级数学成立）、分辨率枚举、Night Shift/原彩读路径、三指中键的私有框架符号层、物理清洁模式的 event tap 进入路径、全局快捷键注册链、Sparkle 更新分发链、动态插件全链（签名校验/catalog Ed25519/下载/加载）、SMC 读、日历/废纸篓/剪贴板/IP/系统状态全家、登录启动状态读取。覆盖窗层级也安全：新 Menubar 窗口在 layer 24，远低于清洁模式/亮度遮罩的 screenSaver 层。

### 需要你上机配合验证的（探针约束无法静默测）
最关键的一项：**菜单栏面板本身**（popover 锚定到假窗口可能错位、点图标关闭的判定可能失效、外点自动收起两轮探针都赶上机器空闲没定论）——跑一次 `make run` 点开面板即知。顺带一轮验证：按一次全局快捷键、三指中键、划词翻译、Night Shift 开关、切一次深浅色外观、开关一次登录启动。SMC 写（充电限制/风扇）和 Sparkle 真实更新留到下次正常使用/发版时确认。

### 只能等 Apple 的
MenuBarHidden 的事件合成面（per-item 窗口没了、右键不路由——维持 fail-closed）；DDC 匹配对 IOMobileFramebufferShim 的单点依赖（shim 再改名才需要动）；log show 的 predicate bug（已绕过，提 Feedback 观察 beta 2）。所有"本 seed 活着"的私有面（CoreBrightness/MultitouchSupport/SkyLight/IOAVService/catalog 签名规范化）建议把本轮探针固化成脚本，每个新 seed 一键重跑。

修复 backlog 共 18 项：立即修 5 项（含上机验证批次）、适配修 8 项、standby 5 项，每项均附 file:line 入口。
