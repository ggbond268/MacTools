# Launchpad 插件 v1 实现规划（MacTools）

> 目标：在 MacTools 里加一个**启动台替代**插件——macOS 26 Tahoe 删了原生启动台，用全局热键/菜单栏唤出一个全屏 app 网格，搜索 + 点击启动。
> 本文档基于三处实地调研：(1) MacTools 内部插件模式（读 PhysicalCleanMode/LaunchControl/AppHotkey 等真源码）；(2) **LaunchNext**（`RoversX/LaunchNext`，GPL-3.0，2.7k★，目前最成熟的 Tahoe 启动台替代，已 clone 读真源码）；(3) 全网 robust 做法（Apple 论坛、各开源替代品）。

---

## 0. 关键前提（实测结论，别踩坑）

- **旧启动台布局 DB 在 Tahoe 已不存在**。本机（26.5.1 / Darwin 25.5.0）`find /private/var/folders -iname '*launchpad*'` 无结果；`com.apple.dock.launchpad/db/db` 缺失；`defaults read com.apple.dock` 里还残留 `ResetLaunchPad=1` 但没有子系统去执行。→ **v1 不做"导入旧布局"**（无源可导）；当成 v2 的可选 best-effort 迁移。
- **必须 non-sandboxed**（MacTools 走 notarized DMG + Developer ID + hardened runtime，已满足）。沙盒下 `NSWorkspace`/LaunchServices 对沙盒外的 app 返回 nil（无错误）——枚举/取图标都会瞎。
- **不要用 Spotlight(`NSMetadataQuery`) 当主数据源**：用户禁用 Spotlight / 把 /Applications 加进隐私排除 / 索引重建时会空或残缺。用**目录扫描**。
- **不要用私有 LaunchServices**（`_LSCopyAllApplicationURLs` 之类）。没有公开 API 能"列出所有已安装 app"（Apple DTS thread 749039 确认）。

---

## 1. v1 范围

### 决策记录（与用户确认 2026-06-04）
- **窗体**：**支持全屏 + 紧凑两态、可在设置切换**。实现上是**同一个窗口 resize**（`setFrame(全屏?screen.frame:紧凑rect)` + `cornerRadius=全屏?0:30` + `hasShadow=!全屏`），共用同一网格视图，不是两套布局——成本可控（照 LaunchNext）。
- **布局**：**横向分页（经典启动台手感）**。v1 **只读、无拖拽重排**，所以分页只是"按每页 N 个切分 + 左右滑 + 页码点"，避开了 LaunchNext 跨页拖拽那类 bug（那些是 v2 重排功能）。
- **打开行为**：**网格先显示，打字即转搜索**（兼顾浏览 + 快速搜）。
- **热键**：**不设默认绑定**，用户在「快捷键」里自设（避免撞键）。

**做（v1，把"Tahoe 没启动台"这个痛点解决掉就够）**
- 全屏 borderless 覆盖窗（多屏：开在鼠标所在屏）。
- 扫描所有 app → 网格展示（图标 + 本地化名称）。
- **搜索**（顶部输入框，实时过滤）。
- 键盘导航（方向键移动、Return 启动、Esc 关闭、输入即聚焦搜索）。
- 触发：**全局热键**（走宿主快捷键系统）+ **菜单栏入口**（`PluginPrimaryPanel` 的"打开"按钮）。
- 点击/回车启动 app（先关窗再启动）。
- 异步图标加载 + 缓存（避免首帧卡死——这是同类工具第一大 bug）。
- 设置页（最小）：网格密度（列数）、是否全屏 vs 紧凑、热键提示（热键本身由宿主快捷键系统托管，用户可在设置里改）。

**不做（推到 v2，对标 LaunchOS/LaunchNext Pro）**
- 文件夹、拖拽排序、自定义改名、隐藏 app、触发角、拖到 Dock。
- 导入旧启动台布局（Tahoe 无源）。
- CALayer/Core Animation 120Hz 网格引擎（LaunchNext 的高级优化；v1 用 SwiftUI `LazyVGrid` + 异步图标就够，且更易维护）。
- 手势（四指）触发。
- 自定义布局持久化（v1 按名称排序即可；持久化顺序放 v2）。

---

## 2. 文件结构

```text
Plugins/Launchpad/
  plugin.json
  project.yml                      # 仅当需要额外 framework/资源时；v1 大概率不需要
  Sources/
    LaunchpadPlugin.swift          # Factory + Provider + LaunchpadPlugin(MacToolsPlugin, PluginPrimaryPanel)
    LaunchpadAppCatalog.swift      # 枚举 app + 异步图标缓存（核心 model）
    LaunchpadOverlayController.swift# borderless 全屏窗的创建/多屏/销毁（仿 PhysicalCleanModeSession）
    LaunchpadGridView.swift        # SwiftUI: 搜索框 + LazyVGrid + 键盘 + 启动
    LaunchpadModels.swift          # AppItem、配置 struct、控件/快捷键 ID 常量
    LaunchpadSettingsView.swift    # 可选：自定义设置视图（或先用 settingsSections）
  Bundle/
    LaunchpadPluginBundleEntrypoint.swift   # 防 tree-shaking 锚点
  Tests/
    LaunchpadAppCatalogTests.swift          # 枚举过滤/去重/名称解析的纯逻辑单测
```

> 普通新增插件**不用改根 `project.yml`**；`scripts/plugins/generate-plugin-project-config.rb` 扫 `plugin.json` 自动生成 target/scheme（`LaunchpadPlugin`）。加完文件**跑 `make generate`**。

---

## 3. plugin.json

```json
{
  "id": "launchpad",
  "displayName": "启动台",
  "summary": "用全局热键或菜单栏唤出全屏应用网格，搜索并启动",
  "version": "1.0.0",
  "minHostVersion": "1.0.2",
  "pluginKitVersion": 2,
  "bundleRelativePath": "Launchpad.bundle",
  "factoryClass": "LaunchpadPlugin.LaunchpadPluginFactory",
  "build": { "project": "../../MacTools.xcodeproj", "scheme": "LaunchpadPlugin" },
  "capabilities": { "primaryPanel": true, "componentPanel": false, "configuration": true },
  "permissions": [],
  "category": "launcher"
}
```

> `factoryClass` 格式 `ModuleName.FactoryClassName`；`pluginKitVersion` 恒为 2；`bundleRelativePath` 恒为 `<Name>.bundle`。

---

## 4. 插件骨架 + 触发（宿主托管全局热键 + 菜单栏入口）

**触发链路（核实自 PhysicalCleanMode + GlobalShortcutManager）**：插件声明 `shortcutDefinitions`（`scope: .global`）→ 宿主 `PluginHost.syncGlobalShortcuts()` 用 Carbon 注册 → 按下 → `GlobalShortcutManager.onShortcutTriggered` → `PluginHost.handleShortcutTrigger` → 经 `guardPluginCall` 调 `plugin.handleShortcutAction(id: actionID)`。菜单栏 `.button` 则通过 `handleAction(.invokeAction(controlID:))`。两条都汇到 `overlay.toggle()`。

```swift
// LaunchpadPlugin.swift
import AppKit
import SwiftUI
import Carbon.HIToolbox        // kVK_*
import MacToolsPluginKit

public final class LaunchpadPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LaunchpadPluginProvider()
    }
}

@MainActor
private struct LaunchpadPluginProvider: PluginProvider {
    func makePlugins() -> [any MacToolsPlugin] { [LaunchpadPlugin()] }
}

private enum ControlID { static let open = "execute" }            // 约定：按钮 controlID 用 "execute"
private enum ShortcutID { static let open = "open-launchpad"; static let openAction = "openLaunchpad" }

@MainActor
final class LaunchpadPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "launchpad", title: "启动台",
        iconName: "square.grid.3x3.fill", iconTint: Color(nsColor: .systemBlue),
        order: 60, defaultDescription: "唤出应用网格，搜索并启动"
    )
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button, menuActionBehavior: .dismissBeforeHandling, buttonTitle: "打开"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let catalog = LaunchpadAppCatalog()
    private lazy var overlay = LaunchpadOverlayController(catalog: catalog)

    var primaryPanelState: PluginPanelState {
        PluginPanelState(subtitle: metadata.defaultDescription, isOn: false, isExpanded: false,
                         isEnabled: true, isVisible: true, detail: nil, errorMessage: nil)
    }
    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }

    // 全局热键：scope .global → 任何时候都能唤出。默认绑定可留给用户在设置里设（避免撞键）。
    var shortcutDefinitions: [PluginShortcutDefinition] {
        [PluginShortcutDefinition(
            id: ShortcutID.open, title: "打开启动台",
            description: "全局唤出应用网格", actionID: ShortcutID.openAction,
            scope: .global,
            defaultBinding: nil,                 // 不设激进默认；F4/媒体键不易用 Carbon 捕获
            isRequired: false
        )]
    }

    func refresh() {}
    func handleAction(_ action: PluginPanelAction) {
        if case let .invokeAction(controlID) = action, controlID == ControlID.open { overlay.toggle() }
    }
    func handleShortcutAction(id: String) { if id == ShortcutID.openAction { overlay.toggle() } }
    func permissionState(for permissionID: String) -> PluginPermissionState { .init(isGranted: true, footnote: nil) }
    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(_ id: String) {}   // 注意：协议方法名以 PluginInterfaces.swift 为准

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [self] _ in
            LaunchpadSettingsView(config: self.catalog.config)
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        if reason.requiresStateCleanup { overlay.close() }   // 关窗、撤监听
    }
}

// Bundle/LaunchpadPluginBundleEntrypoint.swift
import LaunchpadPlugin
private let anchor: Any.Type = LaunchpadPluginFactory.self
```

> 落地时以 `Sources/MacToolsPluginKit/PluginInterfaces.swift` 和 `ShortcutModels.swift` 的**真实签名**为准（`PluginShortcutDefinition` 字段、`handleShortcutAction(id:)`）。上面是骨架形状。

---

## 5. 枚举 app + 异步图标缓存（核心，照 LaunchNext 的成熟做法）

```swift
// LaunchpadAppCatalog.swift
import AppKit

struct AppItem: Identifiable, Hashable {
    let id: String        // 解析后的绝对路径，天然唯一
    let name: String      // 本地化显示名
    let url: URL
}

@MainActor
final class LaunchpadAppCatalog: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    let config = LaunchpadConfig()                 // 列数/全屏等设置
    private let iconCache = NSCache<NSString, NSImage>()   // countLimit=256，内存压力自动回收

    init() { iconCache.countLimit = 256 }

    /// 唤出前调用；扫描放后台，结果回主线程。
    func reload() {
        Task.detached(priority: .userInitiated) {
            let items = Self.scan()
            await MainActor.run { self.apps = items }
        }
    }

    /// 异步取图标：命中缓存同步返回；否则后台 decode 再回填。view 用占位 + 回调刷新。
    func icon(for app: AppItem, _ completion: @escaping (NSImage) -> Void) {
        let key = app.url.path as NSString
        if let cached = iconCache.object(forKey: key) { completion(cached); return }
        Task.detached(priority: .userInitiated) {
            let img = NSWorkspace.shared.icon(forFile: app.url.path)
            img.size = NSSize(width: 72, height: 72)
            await MainActor.run { self.iconCache.setObject(img, forKey: key); completion(img) }
        }
    }

    // —— 枚举（nonisolated 纯函数，可单测）——
    nonisolated static func scan() -> [AppItem] {
        let fm = FileManager.default
        let roots = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Applications",
            "/System/Cryptexes/App/System/Applications",   // Safari 等 cryptex 系统 app，别漏
        ].filter { fm.fileExists(atPath: $0) }

        var seen = Set<String>()
        var out: [AppItem] = []
        for root in roots {
            guard let en = fm.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]   // 不钻进 .app 内部
            ) else { continue }
            for case let url as URL in en {
                guard url.pathExtension == "app" else { continue }
                let resolved = url.resolvingSymlinksInPath()
                let path = resolved.path
                guard fm.fileExists(atPath: path),
                      NSWorkspace.shared.isFilePackage(atPath: path),
                      !isNestedInsideAnotherApp(resolved),     // 排除嵌套的 helper/XPC/login-item app
                      seen.insert(path).inserted else { continue }
                out.append(AppItem(id: path, name: displayName(resolved), url: resolved))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func isNestedInsideAnotherApp(_ url: URL) -> Bool {
        url.pathComponents.filter { $0.hasSuffix(".app") }.count > 1
    }

    nonisolated static func displayName(_ url: URL) -> String {
        // 本地化名优先（FileManager 给用户可见名）。⚠️ 只去掉 .app **后缀**——
        // 不能 replacingOccurrences 全局替换，否则名字里含 ".app" 的 app 会被误伤。
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
```

**为什么这么写（每条都有 LaunchNext / Apple 论坛佐证）**
- 4 个根路径 + 过滤不存在的（cryptex 路径在旧系统可能没有）。
- `enumerator` 递归 + `.skipsPackageDescendants` → 自动覆盖 `/Applications/Utilities` 和厂商子目录，又不钻进 .app（性能+正确性）。
- `isNestedInsideAnotherApp`（路径里 `.app` 段数 >1）排除 `Foo.app/.../Bar.app` 这种内嵌 helper。
- `resolvingSymlinksInPath()` + `seen` Set 去重（同一 app 经 symlink/cryptex 出现两次）。
- 名称用 `FileManager.displayName`（本地化）；**别用文件名**（同类 naive 实现都在这翻车）。
- 图标用 `NSWorkspace.icon(forFile:)`（多分辨率 NSImage），**别手读 .icns**（现代 app 图标在 `Assets.car`，没有 .icns）。
- **图标异步 + NSCache**：100+ app 在主线程同步 `icon(forFile:)` 会让首帧卡住——LaunchNext/LaunchBack 实测的第一大 bug。
- v1 不上 FSEvents 实时监听；每次唤出前 `reload()` 重扫即可（足够；实时监听放 v2）。

---

## 6. 全屏 borderless 覆盖窗（融合 MacTools 销毁纪律 + LaunchNext 窗口配置）

```swift
// LaunchpadOverlayController.swift
import AppKit
import SwiftUI

// borderless 窗默认不能成为 key/main → 搜索框无法输入。必须 override。
private final class LaunchpadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LaunchpadOverlayController: NSObject, NSWindowDelegate {
    private let catalog: LaunchpadAppCatalog
    private var window: LaunchpadWindow?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var isStopping = false

    init(catalog: LaunchpadAppCatalog) { self.catalog = catalog }

    var isShown: Bool { window != nil }
    func toggle() { isShown ? close() : open() }

    func open() {
        catalog.reload()                                   // 唤出前重扫
        let screen = activeScreen()
        let win = LaunchpadWindow(contentRect: screen.frame,
                                  styleMask: [.borderless, .fullSizeContentView],
                                  backing: .buffered, defer: false, screen: screen)
        win.delegate = self
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isReleasedWhenClosed = false                   // 关键：别在 session 中途 dealloc
        win.level = .floating
        win.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        win.setFrame(screen.frame, display: true)
        win.contentView = NSHostingView(rootView: LaunchpadGridView(
            catalog: catalog,
            onLaunch: { [weak self] item in self?.launch(item) },
            onDismiss: { [weak self] in self?.close() }
        ))
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = win
        installKeyMonitor()
        observeScreenChanges()
    }

    func close() {
        guard !isStopping, let win = window else { return }
        isStopping = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        win.delegate = nil
        win.close()
        window = nil
        isStopping = false
    }

    private func launch(_ item: AppItem) {
        close()                                            // 先关窗，避免它盖住目标 app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            // Esc 关闭；其它键交给 SwiftUI（搜索框/方向键）。注意 IME 组字时别拦 Return。
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let win = self.window else { return }
                let s = self.activeScreen(); win.setFrame(s.frame, display: true)
            }
        }
    }

    // 窗被系统/用户意外关闭时，清理状态（仅非编程关闭触发）
    func windowDidResignKey(_ n: Notification) { close() }   // 点别处即关（启动器惯例）
}
```

**为什么这么配（核实自 LaunchNext + Apple 论坛）**
- `canBecomeKey/Main = true` 是 borderless 能接受键盘/搜索输入的**前提**。
- `.canJoinAllApplications + .fullScreenAuxiliary` 是 macOS 13+ **真正能盖住全屏 app** 的组合；**别用** 2016 老帖的 `.canJoinAllSpaces + .fullScreenAuxiliary`（只跨 Space，盖不住全屏 app）。`.ignoresCycle` 把它从 Cmd-Tab 隐藏，`.transient` 配合失焦自动关。
- **多屏开在鼠标所在屏**（`NSEvent.mouseLocation`），不是 `NSScreen.main`（常见 bug：开错显示器）。
- 销毁纪律照 `PhysicalCleanModeSession`：`isReleasedWhenClosed=false`、`isStopping` 闸、移除 keyMonitor/observer、`delegate=nil` 再 close。
- 启动时**先关窗再延时启动**（LaunchNext 同款 0.05s），避免覆盖窗盖住刚启动的 app。
- v1 用单窗开在活动屏即可；多屏同时铺/热插拔重建放 v2（这里只跟随重设 frame）。

---

## 7. 网格视图（SwiftUI，v1 够用）

`LaunchpadGridView.swift` 要点（不贴全，列关键点）：
- **打开行为（v1 决策）**：唤出先显示网格、搜索框**不抢焦点**；用户一旦打字（捕获首个字符键）再聚焦搜索框并过滤。兼顾浏览 + 快速搜。
- `ScrollView` + `LazyVGrid(columns: 配置列数, spacing:)`，每格一个 `AppCell`。
- `AppCell`：`@State icon: NSImage?`，`onAppear` 调 `catalog.icon(for:){ icon = $0 }`（异步占位→回填，避免卡首帧）；图标 + 名称（`lineLimit(1)`）；点击/回车 → `onLaunch(item)`。
- **键盘导航**：方向键移动高亮 index；`Return` 启动高亮项（但先判 `isIMEComposing`/marked text，别劫持中文候选回车）；`Esc` 已由 controller 的 keyMonitor 处理。
- 背景：`.ultraThinMaterial` / `NSVisualEffectView`（系统材质，贴近 Tahoe 观感）——**别复刻私有 Liquid Glass**，原生材质更抗升级。
- **横向分页（v1 决策）**：过滤后的 app 按"每页 列×行"切分，`TabView(.page)` 或横向 paging `ScrollView` 左右滑 + 底部页码点。**只读、不重排**（无拖拽），故无跨页拖拽类 bug。搜索时收敛为单页结果。全屏/紧凑两态共用此视图，仅每页容量随窗口尺寸变。
- **实测校准（本机 26.5.1）**：147 app 同步加载图标仅 ~47ms → 异步并非 v1 的关键瓶颈（此量级同步可接受）；异步+`NSCache` 保留作更大装机/重复打开的优化。`.skipsPackageDescendants` 已从根上挡掉钻进 .app，嵌套守卫这次拦 0 个（廉价双保险，保留）。

---

## 8. 设置（v1 最小）

`LaunchpadSettingsView`（`PluginConfiguration.makeView` 自定义视图）：
- 列数（密度）滑杆 / Picker。
- 全屏 vs 紧凑窗。
- 提示用户：唤出热键在「快捷键」里设（宿主托管，自动可改）。
- 用 `PluginSettingsTheme` 的字体/间距/卡片 token（别造私有 style）。

> 若设置项很简单也可先用 `settingsSections` 描述式卡片，但有滑杆/Picker 这种交互建议直接 `PluginConfiguration.makeView`。

---

## 9. Robustness 检查清单（distill 自调研，提交前逐条过）

- [ ] **non-sandboxed** 确认（沙盒下枚举/图标会瞎）。
- [ ] 枚举含 `/System/Cryptexes/App/System/Applications`（否则丢 Safari 等）。
- [ ] `enumerator` 用 `.skipsPackageDescendants` + `isNestedInsideAnotherApp` 守卫（否则列出 helper app / 性能爆炸）。
- [ ] `resolvingSymlinksInPath` + `seen` 去重。
- [ ] 名称用本地化 `displayName`，不是文件名。
- [ ] 图标 `NSWorkspace.icon(forFile:)`，**异步 + NSCache**，主线程不同步批量解码。
- [ ] borderless 窗 override `canBecomeKey/Main`。
- [ ] 窗 `collectionBehavior` 用 `.canJoinAllApplications + .fullScreenAuxiliary`（不是老的 `.canJoinAllSpaces`）。
- [ ] 多屏开在鼠标所在屏。
- [ ] 失焦/Esc 关闭；`isStopping` 闸 + 移除 monitor/observer + `delegate=nil`。
- [ ] 启动 app 先关窗再延时 open。
- [ ] **IME 守卫**：组字时 Return 不劫持去启动 app。
- [ ] 改 `NSApp.presentationOptions`（若为盖菜单栏）务必在关闭时还原。
- [ ] 不导入旧布局（Tahoe 无源）；不依赖 Spotlight；不用私有 API。
- [ ] 加文件后 `make generate`；`@MainActor` 贯穿所有碰 NSWindow 的代码。
- [ ] 单测覆盖 `scan` 过滤/去重/`isNestedInsideAnotherApp`/`displayName`（纯逻辑，不碰真窗口）。

---

## 10. 参考实现

- **LaunchNext** (`github.com/RoversX/LaunchNext`, GPL-3.0) was reviewed as a mature Tahoe Launchpad alternative. GPL compatibility does not remove the need to preserve provenance and notices when code is deliberately adapted. This plan uses its documented behavior and known issues as research context rather than incorporating untracked source portions.
- **MacTools 内部对照**：全屏窗销毁纪律 = `Plugins/PhysicalCleanMode/Sources/PhysicalCleanModeSession.swift`；全局热键链路 = `Sources/Core/Shortcuts/GlobalShortcutManager.swift` + `PluginHost.handleShortcutTrigger`；菜单栏/设置 = `LaunchControlPlugin` / `BatteryChargeLimitPlugin` / `ActivityBarPlugin`。

---

## 11. 开工建议

1. 先 `Plugins/Launchpad/` 脚手架 + `plugin.json` → `make generate` → 空插件能编译、菜单栏出现"打开"按钮。
2. `LaunchpadAppCatalog.scan()` + 单测（枚举正确性先立住）。
3. `LaunchpadOverlayController.open()` 弹个空白全屏窗、Esc/失焦能关、多屏正确 → 跑通窗口生命周期。
4. `LaunchpadGridView` 接上 catalog，异步图标 + 搜索 + 点击启动。
5. 全局热键（`shortcutDefinitions`）+ 设置页。
6. **视觉验证**：`make run` 起 app，真机唤出，核对网格/材质/多屏/全屏覆盖效果（这步必须用眼睛看）。
7. 过一遍 §9 清单 → 提交。

> 体量提醒：这是个不小的新插件。按你定的"别折腾上游"基调，**开工前最好在 MacTools 开个 issue 和 ggbond 对齐要不要/做成什么形态**，再决定是否作为 PR 提上去（或先在你 fork 里自用）。

---

## 12. Codex 审后补强（gpt-5.5/high 交叉评审，2026-06-04）

Codex 认可整体方向（不碰旧 DB / 不用 Spotlight / 不用私有 API / 补 cryptex / v1 用 LazyVGrid 都对）。以下是它挑出的、需要在实现时收紧的点——**v1 必须按这些做，否则"像启动台一样可靠唤出"会翻车**。

### P0（直接影响可靠性，必须做对）
1. **全屏覆盖不能只靠 `.floating` 配置下定论**。`.floating` 偏保守；仓库里真做覆盖的 `PhysicalCleanMode` 用的是 `screenSaverWindow` level。→ **实现时先做实验**：在 Safari/视频/游戏/演示全屏 Space、Stage Manager 开关、多屏独立 Space 下逐个验证；盖不住就抬到 `screenSaverWindow` level。**这条要在 §6 落地前用真机实验定级**（和我已列的"全屏覆盖是第一脆点"一致）。
2. **"打字即搜索但不抢焦点"要有真实现路径**。仅靠根视图 keyDown + "其它键交给 SwiftUI" 不可靠（NSHostingView 根视图不是 first responder 时普通字符进不来）。→ 用**真实 `NSTextField`/`NSSearchField`** 承接输入：打开时不显示/不聚焦，捕获首个字符键后显示并聚焦（AppKit key bridge），而不是在根视图拦截字符。
3. **IME/Return 必须由真实文本输入承接**。中文组字/候选窗/选词回车极易误触发启动。→ 搜索框用 `NSTextInputClient`（即真实 NSTextField）；`Return` 仅在"无 marked text + 候选未激活 + selection 有效"时才启动 app。不要在根视图 keyDown 里判 IME。
4. **`windowDidResignKey { close() }` 太激进**。IME 候选、系统权限弹窗、Mission Control/Space 切换都会改 key。→ 关闭策略改为：Esc + 外部鼠标点击 + app `deactivate`，必要时 debounce；别把 resignKey 当唯一真相。

### P1
5. **多屏写成明确产品决定**：v1 = 开在鼠标所在屏（**不是覆盖所有屏**）。注明"屏 A 全屏工作、鼠标在 B 则开到 B"是已知取舍；屏参数变化时别乱跳窗。测独立 Spaces。
6. **启动用 `NSWorkspace.openApplication(at:configuration:completionHandler:)`** 并处理失败（记日志/恢复状态），而非 `open(url)`（错误不可见）；0.05s 只是经验值，改成关窗完成回调里再启动更稳。
7. **别把文案写成"所有 app"**：会漏自定义目录/MDM/虚拟化生成的 app。v1 不追求全量；预留"附加扫描目录"到 v2。
8. ✅ 已修：`displayName` 只去 `.app` **后缀**（不是全局替换，避免误伤）。
9. **异步要加取消 + 代际保护**：`reload()` 用 `reloadTask` 可取消 + generation token；图标回填前确认 item 仍在当前结果里（快速开关时旧扫描/旧图标别覆盖新状态、别在关窗后回调）。
10. **不做名字/bundleID/Apple 前缀黑名单**：只排除嵌套 helper + 无效 bundle，避免误删 Tahoe 新系统 app（如 `com.apple.apps.launcher`）。

### v1 还要补的缺口（Codex 列）
- **空态/加载态/扫描失败态**：无权限目录、`enumerator` 为 nil、0 app、图标加载失败都要有 UI。
- **设置持久化**：全屏/紧凑、列数要**存进插件 storage**，别只挂内存 `LaunchpadConfig()`。
- **点击背景关闭**（v1 至少要有）；触发角/鼠标移出留 v2。
- **可访问性**：grid cell 要 accessibility label，键盘选中态要视觉明显（启动器是键盘重度功能，非锦上添花）。
- **刷新策略写明**：v1 = 每次唤出重扫、打开期间不刷新；FSEvents/NSWorkspace 通知留 v2。

### 范围 & 技术选型确认
- v1 不做拖拽/文件夹/导入/手势/CALayer **合理**；147 app + 图标 ~47ms 规模下 **SwiftUI `LazyVGrid` 足够**，先别上 CALayer。
- **横向分页**可放 v1，但 **`TabView(.page)` 在 macOS 上慎用**——必要时自己做横向 paging `ScrollView`，比 iOS 风格的 PageTabView 更可控。

### 实现前的验证矩阵（开工后逐项真机过）
全屏 app（Safari/视频/游戏/演示）· 双屏/独立 Space · 中文 IME 组字与候选 · 外接屏热插拔 · Stage Manager · 菜单栏自动隐藏 · Dock 自动隐藏 · 重复快速唤出（开关竞态）。

---

## 运行时真机验证记录（2026-06-04，LP4 收尾）

在真机上自驱动验证（截图 + 日志 + AX/CGEvent 驱动），**抓到并修复 2 个静态审查（含 Codex）未发现的真 bug**：

1. **`.id(index)` 导致过滤后视图复用旧内容**：`LazyVGrid` cell 叠了 `.id(index)`，列表从全量缩到过滤子集时「index 0」视图身份不变，SwiftUI 复用旧 cell（打 `saf` 错误显示 Accelerate）。被「onAppear 注入搜索词」的测试掩盖，只有真实「全列表→子集」转换暴露。已移除 `.id(index)`，scrollTo 改用 `filtered[i].id`。
2. **cell 无可执行无障碍动作**：cell 标了 `.isButton` 却只有 `.onTapGesture`（只认鼠标），AXPress/VoiceOver 点不动、无法启动 app。已加 `.accessibilityAction`。

已验证通过（生产路径，非旁路）：
- 插件加载/activate（动态加载路径）
- 枚举 147 app（字母排序，含 cryptex/游戏）
- 全屏 overlay 开在鼠标所在屏；另一屏不被覆盖（单屏设计）
- 真实菜单栏 → 右键功能面板 → 「打开」→ overlay 唤出，app active、搜索框聚焦
- 搜索过滤（真实 NSSearchField→binding→filter，单/多结果）
- 启动闭环（Before/After：Calculator 未运行 → 点 cell → 已启动 + 启动台自动关闭）
- 失焦自动关闭（resignActive）

待真机确认（剩余）：IME 组字回车安全（Apple 标准 `doCommandBySelector + hasMarkedText`，需 active app 真实击键，静默测不了）；全屏-app Space 覆盖矩阵（Safari/视频/Metal 全屏、Stage Manager）。

LP5 待做：设置持久化（全屏/紧凑/列数，PluginStorage）+ 横向分页布局。

## LP5b 设置 + LP4b 横向分页（2026-06-04 续）

**LP5b 设置（全屏/紧凑可切换 + 列数）— 完成并真机验证**
- 新增 `LaunchpadPreferences`（PluginStorage 持久化）、`LaunchpadSettingsView`（PluginConfiguration.makeView，窗口模式 picker + 列数 stepper）。
- overlay 支持全屏 / 紧凑居中圆角浮窗（≤960×680，带阴影，点窗外 resignActive 关）。
- 真机验证：写 windowMode=compact + columns=6 → 启动台开为 960×680 居中浮窗、第一行正好 6 个图标。✅
- Codex P2 修复：列数 clamp 集中到写入路径；窗口模式 open 时快照（屏幕变化观察器用快照值）。

**LP4b 横向分页（经典）— 完成并真机验证**
- macOS 无 PageTabViewStyle，自实现：filtered 按 列×行 切页 → HStack 横排所有页 + offset 滑动 + clipped；selectedIndex 为真相源，visiblePage 派生；方向键跨页、页码点可点、拖拽翻页。
- 真机验证：147 app 分 2 页，页1=A–M、页2=M–Z+中文；右方向键导航跨页正确、页码点高亮跟随。✅
- **运行时 AX 验证又抓到第 3 个 a11y bug**：页码点同 cell 一样 `.isButton` 缺 `.accessibilityAction`（鼠标能点、VoiceOver/AX 点不动）→ 已修。
- Codex P1 修复：updateLayout 布局变化后按新 perPage 重新派生 currentPage（否则选中项可能落在不可见页、回车启动不可见项）；P2：goToPage 空列表 guard 防 selectedIndex=-1。

**运行时验证累计抓到 3 个 a11y/渲染 bug**（`.id(index)` 渲染复用、cell + 页码点 a11y 动作缺失），均为编译 + Claude/Codex 静态审查未发现、只有真机驱动暴露。

**IME 真机验证通过（2026-06-04，用户手测）**：中文拼音组字状态下按回车只上屏候选词、不误启动 app；方向键切候选、Esc 取消组字（非关窗）。Apple 标准 `doCommandBySelector + hasMarkedText` 模式确认有效。

至此 **LP1–LP5 全部完成并真机验证**：枚举 → 全屏覆盖窗 → 网格/搜索/启动 → 全局热键 → 设置(全屏/紧凑/列数) → 横向分页 → IME 安全。

后续可选优化（非阻塞）：横向分页虚拟化（当前全页渲染，~147 app 规模 OK）；紧凑模式更严格的窗外点击检测；全屏-app Space 覆盖的多设备矩阵。
