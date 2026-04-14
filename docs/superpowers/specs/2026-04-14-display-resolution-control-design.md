# 显示器分辨率控制插件 · 设计文档

- **日期**：2026-04-14
- **目标版本**：MacTools 0.3.0（或下一个 minor 版本）
- **作者**：brainstorming session

## 1. 背景与目标

MacTools 是一款插件化 macOS 菜单栏工具，当前内置两个插件（物理清洁模式、阻止休眠）。本次新增「显示器分辨率」插件，允许用户在菜单栏内快速查看并切换每个显示器的分辨率。

### 1.1 功能范围（MVP）

- 在菜单栏插件列表中新增一行「显示器分辨率」，点击整行展开内嵌列表
- 列出所有活跃显示器，每个显示器一个 section，section 内是按分辨率由高到低排序的单列表
- 同宽高比筛选：仅显示与显示器原生比例一致的模式
- 点击某项立即通过 `CGCompleteDisplayConfiguration(.permanently)` 切换，写入系统偏好
- 支持多显示器，各屏独立切换
- 基于 CoreGraphics 公共 API，零私有 API 依赖，无额外权限

### 1.2 非目标（明确排除）

- 不提供刷新率切换（多刷新率折叠为最高值）
- 不提供快捷键
- 不提供确认对话框 / 15 秒自动回退
- 不实现 `CGDisplayRegisterReconfigurationCallback` 动态监听（每次打开菜单现算）
- 不支持镜像拓扑管理
- 不支持虚拟/Dummy 显示器（DisplayLink、sidecar 等）
- 不提供 `.forSession` / `.forAppOnly` 临时切换选项

### 1.3 设计取舍摘要

| 决策点 | 选择 | 理由 |
|---|---|---|
| UI 形态 | 展开式行内列表 | 沿用现有插件布局，一致性最高 |
| 持久化 | `.permanently` | 符合设置器类交互习惯 |
| 多显示器 | 全部列出 | 与 macOS System Settings 行为一致 |
| 插件开关语义 | 无开关，整行即入口 | 分辨率非开关式功能，需扩展 `PluginControlStyle` |
| 列表内容 | 单一列表 + 同宽高比筛选 | UI 简洁，对齐系统默认视图 |
| 刷新率 | 不展示 | 典型用户无需，与系统默认视图一致 |
| 快捷键 | 不提供 | 切到具体分辨率的快捷键语义不明确 |
| 动态监听 | 不集成 | YAGNI，4 屏 < 10ms 枚举足够 |
| 安全兑底 | 点击即用 | Safe flag + isUsableForDesktopGUI 已过滤不安全模式 |

## 2. 架构总览

### 2.1 目录布局

```
Sources/
  Core/
    Plugins/
      PluginModels.swift           # 【改】新增 .disclosure / .selectList / sectionTitle
  Features/
    DisplayResolution/             # 【新】完整模块
      DisplayResolutionPlugin.swift          # 插件入口
      DisplayResolutionController.swift      # CoreGraphics 封装（服务层）
      DisplayResolutionInfo.swift            # 值类型 DisplayResolutionInfo + DisplayInfo
      DisplayModeFlags.swift                 # IOKit flags 常量
  App/
    MenuBarContent.swift           # 【改】新增 .disclosure 行 + .selectList 渲染
  Core/
    Diagnostics/
      AppLog.swift                 # 【改】新增两个 logger category
```

### 2.2 分层职责

| 层 | 文件 | 职责 | 依赖 |
|---|---|---|---|
| Service | `DisplayResolutionController` | 枚举/切换分辨率，CoreGraphics 全部封装在此 | CoreGraphics, AppLog |
| Model | `DisplayResolutionInfo` / `DisplayInfo` | 纯值类型，跨层传递 | Foundation, CoreGraphics (typealias 用) |
| Constants | `DisplayModeFlags` | IOKit flags 位值 | — |
| Plugin | `DisplayResolutionPlugin` | 编排：调 Controller 取数据 → 组装 `panelState` / `panelDetail` → 处理 `handlePanelAction` | Core/Plugins |
| UI | `MenuBarContent`（增量） | 渲染 `.disclosure` 行 + `.selectList` 控件 | SwiftUI |

### 2.3 关键约束

- **CoreGraphics 只出现在 Controller 一处**：plugin 和 UI 层只见到值类型
- **Controller 无状态**：每次 `listAvailableResolutions` 现算，plugin 也不做缓存
- **所有 CG 调用走主线程**：`DisplayResolutionController` 与 `DisplayResolutionPlugin` 均标注 `@MainActor`
- **CGDisplayMode 指针不跨方法缓存**：仅缓存 `ioDisplayModeID: Int32`，apply 时按 id 重新 fetch

## 3. 服务层：DisplayResolutionController

### 3.1 接口

```swift
@MainActor
final class DisplayResolutionController {
    func listConnectedDisplays() -> [DisplayInfo]

    func listAvailableResolutions(
        for displayID: CGDirectDisplayID
    ) -> [DisplayResolutionInfo]

    @discardableResult
    func applyResolution(
        _ info: DisplayResolutionInfo,
        for displayID: CGDirectDisplayID
    ) -> Result<Void, DisplayResolutionError>
}
```

### 3.2 值类型

```swift
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
}

struct DisplayResolutionInfo: Equatable {
    let modeId: Int32          // CGDisplayModeGetIODisplayModeID，稳定身份
    let width: Int             // 逻辑宽 (pt)
    let height: Int            // 逻辑高 (pt)
    let pixelWidth: Int        // 物理宽 (px)
    let pixelHeight: Int       // 物理高 (px)
    let refreshRate: Double    // Hz，不报则 0
    let isHiDPI: Bool          // pixelWidth > width
    let isNative: Bool         // kDisplayModeNativeFlag
    let isDefault: Bool        // kDisplayModeDefaultFlag
    let isCurrent: Bool        // modeId == CGDisplayCopyDisplayMode().ioDisplayModeID

    var displayTitle: String { "\(width)×\(height)" }
    var aspectRatio: Double  { Double(width) / Double(height) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.modeId == rhs.modeId }
}

enum DisplayResolutionError: Error, LocalizedError {
    case modeNotFound(modeId: Int32)
    case beginConfigFailed(CGError)
    case configureFailed(CGError)
    case completeFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .modeNotFound:       return "分辨率模式已失效"
        case .beginConfigFailed:  return "无法开始显示配置"
        case .configureFailed:    return "配置显示模式失败"
        case .completeFailed:     return "提交显示配置失败"
        }
    }
}
```

### 3.3 `listConnectedDisplays` 实现

1. `CGGetActiveDisplayList` 获取所有活跃显示器 ID（最多 16 个）
2. 过滤镜像副屏：若 `CGDisplayIsInMirrorSet(id)` 为 true 且不是镜像主屏，跳过
3. 每个显示器读取：
   - ID：`CGDirectDisplayID`
   - 名称：通过 `NSScreen.screens` 反查 `localizedName`（`NSScreen` 的 `deviceDescription["NSScreenNumber"]` 对应 displayID）；fallback 为 `"Display \(index + 1)"`
   - `isBuiltin`：`CGDisplayIsBuiltin`
   - `isMain`：`CGDisplayIsMain`

### 3.4 `listAvailableResolutions` 实现

严格按 brainstorming 输入中的算法：

```swift
func listAvailableResolutions(for displayID: CGDirectDisplayID) -> [DisplayResolutionInfo] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
        AppLog.displayResolutionController.error("CGDisplayCopyAllDisplayModes returned nil for displayID \(displayID)")
        return []
    }

    let currentId = CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID ?? 0

    let candidates = raw.filter { mode in
        guard mode.isUsableForDesktopGUI() else { return false }
        let f = mode.ioFlags
        guard f & DisplayModeFlags.safe != 0 else { return false }
        guard f & DisplayModeFlags.notPreset == 0 else { return false }
        return true
    }
    guard !candidates.isEmpty else { return [] }

    var best: [String: CGDisplayMode] = [:]
    for mode in candidates {
        let f = mode.ioFlags
        let tag: String
        if f & DisplayModeFlags.native != 0       { tag = "native" }
        else if f & DisplayModeFlags.default != 0 { tag = "default" }
        else                                      { tag = "scaled" }
        let key = "\(tag):\(mode.width)x\(mode.height)"
        if let existing = best[key] {
            if mode.refreshRate > existing.refreshRate { best[key] = mode }
        } else {
            best[key] = mode
        }
    }

    let infos = best.values.map { mode -> DisplayResolutionInfo in
        let f = mode.ioFlags
        return DisplayResolutionInfo(
            modeId:      mode.ioDisplayModeID,
            width:       mode.width,
            height:      mode.height,
            pixelWidth:  mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            isHiDPI:     mode.pixelWidth > mode.width,
            isNative:    f & DisplayModeFlags.native  != 0,
            isDefault:   f & DisplayModeFlags.default != 0,
            isCurrent:   mode.ioDisplayModeID == currentId
        )
    }

    return infos.sorted {
        $0.pixelWidth != $1.pixelWidth ? $0.pixelWidth > $1.pixelWidth : $0.width > $1.width
    }
}
```

### 3.5 `applyResolution` 实现

```swift
@discardableResult
func applyResolution(
    _ info: DisplayResolutionInfo,
    for displayID: CGDirectDisplayID
) -> Result<Void, DisplayResolutionError> {
    guard let target = fetchCGDisplayMode(modeId: info.modeId, displayID: displayID) else {
        return .failure(.modeNotFound(modeId: info.modeId))
    }

    var config: CGDisplayConfigRef?
    let beginErr = CGBeginDisplayConfiguration(&config)
    guard beginErr == .success, let config else {
        return .failure(.beginConfigFailed(beginErr))
    }

    let configureErr = CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
    guard configureErr == .success else {
        CGCancelDisplayConfiguration(config)
        return .failure(.configureFailed(configureErr))
    }

    let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
    guard completeErr == .success else {
        return .failure(.completeFailed(completeErr))
    }

    return .success(())
}

private func fetchCGDisplayMode(
    modeId: Int32,
    displayID: CGDirectDisplayID
) -> CGDisplayMode? {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
        return nil
    }
    return modes.first(where: { $0.ioDisplayModeID == modeId })
}
```

**事务安全关键点**：
- `CGBegin` 失败时 **不调** `CGCancel`（事务未开始）
- `CGConfigure` 失败时 **必须调** `CGCancel`
- `CGComplete` 失败时 **不再调** `CGCancel`（事务已半提交，由 macOS 自行回滚）

### 3.6 IOKit Flags 常量

`DisplayModeFlags.swift`：

```swift
enum DisplayModeFlags {
    static let valid: UInt32      = 0x0000_0001
    static let safe: UInt32       = 0x0000_0002
    static let `default`: UInt32  = 0x0000_0004
    static let notPreset: UInt32  = 0x0000_0200
    static let native: UInt32     = 0x0200_0000
}
```

常量来自 `IOKit/graphics/IOGraphicsTypes.h`，未桥接到 Swift，必须硬编码。

## 4. Plugin 层：DisplayResolutionPlugin

### 4.1 Manifest

```swift
let manifest = PluginManifest(
    id: "display-resolution",
    title: "显示器分辨率",
    iconName: "display",
    iconTint: Color(nsColor: .systemBlue),
    controlStyle: .disclosure,
    menuActionBehavior: .keepPresented,
    order: 30,                              // 在 KeepAwake(50) 之前
    defaultDescription: "查看并切换每个显示器的分辨率"
)
```

### 4.2 状态字段

```swift
private var isExpanded: Bool = false
private var lastErrorMessage: String?
private let controller = DisplayResolutionController()
```

### 4.3 `panelState` 组装

```swift
var panelState: PluginPanelState {
    let displays = controller.listConnectedDisplays()

    guard !displays.isEmpty else {
        return PluginPanelState(
            subtitle: "未检测到可用显示器",
            isOn: false,
            isEnabled: false,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    return PluginPanelState(
        subtitle: subtitleForCollapsedState(displays),
        isOn: isExpanded,                   // .disclosure 语义：是否展开
        isEnabled: true,
        isVisible: true,
        detail: isExpanded ? buildDetail(for: displays) : nil,
        errorMessage: lastErrorMessage
    )
}
```

`subtitleForCollapsedState`：
- 单屏：`"主屏 3008×1692"`
- 多屏：`"3 个显示器"`

### 4.4 `buildDetail` 实现

```swift
private func buildDetail(for displays: [DisplayInfo]) -> PluginPanelDetail {
    let controls = displays.flatMap { display -> [PluginPanelControl] in
        let modes = controller.listAvailableResolutions(for: display.id)
        guard !modes.isEmpty else { return [] }

        let filtered = Self.filterSameAspectRatio(modes)

        let options = filtered.map { mode in
            PluginPanelControlOption(
                id: String(mode.modeId),
                title: Self.optionTitle(for: mode)
            )
        }
        let currentID = filtered.first(where: { $0.isCurrent }).map { String($0.modeId) }

        return [
            PluginPanelControl(
                id: "display.\(display.id)",
                kind: .selectList,
                options: options,
                selectedOptionID: currentID,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: display.name,
                isEnabled: true
            )
        ]
    }

    return PluginPanelDetail(controls: controls)
}

static func filterSameAspectRatio(
    _ modes: [DisplayResolutionInfo]
) -> [DisplayResolutionInfo] {
    guard let first = modes.first else { return [] }
    let nativeAspect = modes.first(where: { $0.isNative })?.aspectRatio ?? first.aspectRatio
    return modes.filter { abs($0.aspectRatio - nativeAspect) < 0.01 }
}

static func optionTitle(for mode: DisplayResolutionInfo) -> String {
    var title = "\(mode.width)×\(mode.height)"
    if mode.isNative { title += " (原生)" }
    else if mode.isDefault { title += " (默认)" }
    return title
}

static func parseDisplayID(from controlID: String) -> CGDirectDisplayID? {
    let prefix = "display."
    guard controlID.hasPrefix(prefix) else { return nil }
    return CGDirectDisplayID(controlID.dropFirst(prefix.count))
}
```

### 4.5 `handlePanelAction`

```swift
func handlePanelAction(_ action: PluginPanelAction) {
    switch action {
    case let .setSwitch(isOn):
        isExpanded = isOn
        lastErrorMessage = nil
        onStateChange?()

    case let .setSelection(controlID, optionID):
        guard
            let displayID = Self.parseDisplayID(from: controlID),
            let modeId = Int32(optionID),
            let target = controller
                .listAvailableResolutions(for: displayID)
                .first(where: { $0.modeId == modeId })
        else {
            return
        }

        switch controller.applyResolution(target, for: displayID) {
        case .success:
            lastErrorMessage = nil
            AppLog.displayResolutionPlugin.info("applied \(target.width)×\(target.height) on display \(displayID)")
        case .failure(let error):
            AppLog.displayResolutionPlugin.error("apply failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = "切换失败：\(error.localizedDescription)"
        }
        onStateChange?()

    case .setDate:
        return  // 不使用
    }
}
```

### 4.6 协议其余方法

- `permissionRequirements: [] ` — 无权限需求
- `settingsSections: []` — 无设置页 section
- `shortcutDefinitions: []` — 无快捷键
- `refresh()` — 空实现，状态每次通过 `panelState` getter 现算
- `permissionState(for:)` — 返回 `PluginPermissionState(isGranted: true, footnote: nil)`
- `handlePermissionAction(id:)` / `handleSettingsAction(id:)` / `handleShortcutAction(id:)` — 空实现

### 4.7 PluginHost 注册

`Sources/Core/Plugins/PluginHost.swift` 的 `convenience init()` 修改：

```swift
self.init(
    plugins: [
        DisplayResolutionPlugin(),
        KeepAwakePlugin(),
        PhysicalCleanModePlugin()
    ],
    ...
)
```

## 5. 插件模型扩展

### 5.1 `PluginModels.swift` 改动

```swift
enum PluginControlStyle {
    case `switch`
    case disclosure   // 【新】行右侧显示 chevron，整行可点击
}

enum PluginPanelControlKind {
    case segmented
    case datePicker
    case selectList   // 【新】多行可点击列表，当前项带 checkmark
}

struct PluginPanelControl: Identifiable {
    let id: String
    let kind: PluginPanelControlKind
    let options: [PluginPanelControlOption]
    let selectedOptionID: String?
    let dateValue: Date?
    let minimumDate: Date?
    let displayedComponents: DatePickerComponents?
    let datePickerStyle: PluginPanelDatePickerStyle?
    let sectionTitle: String?   // 【新】仅 .selectList 使用，nil 表示无标题
    let isEnabled: Bool
}
```

### 5.2 现有调用点回填

`KeepAwakePlugin.panelDetail` 中构造 `PluginPanelControl` 的两处（duration 段选控件、customEndDate datePicker 控件）都需要新增 `sectionTitle: nil`。

`PhysicalCleanModePlugin` 如果有 `PluginPanelControl` 构造点，同样处理。

### 5.3 设计理由

**为什么 `sectionTitle` 放在 `PluginPanelControl` 而非独立 section**：
- YAGNI：目前只有分辨率插件需要分组，且每个 section 恰好对应一个 `.selectList`
- 侵入最小：不改 `PluginPanelDetail` 的扁平结构
- 未来若出现"多控件共享 section"的需求再重构为 `PluginPanelSection`

**为什么 `.disclosure` 复用 `.setSwitch(Bool)` action 而非新增 `.setExpanded(Bool)`**：
- 语义由 plugin 内部重新解释为"是否展开"
- 避免分叉 action 枚举，MenuBarContent 不需要新分支
- `isOn` 字段意义对 plugin 透明，对 UI 透明

## 6. UI 层：MenuBarContent 渲染扩展

### 6.1 `FeatureRowView` 控制样式分支

```swift
switch item.controlStyle {
case .switch:
    Toggle(String(), isOn: $isOn)
        .labelsHidden()
        .controlSize(.small)
        .toggleStyle(.switch)
        .disabled(!item.isEnabled)

case .disclosure:
    Image(systemName: isOn ? "chevron.up" : "chevron.down")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
}
```

### 6.2 整行点击手势

`.disclosure` 行需要整行响应点击。`FeatureRowView` 最外层加 `onTapGesture`，条件仅在 `controlStyle == .disclosure` 时启用：

```swift
.contentShape(Rectangle())
.onTapGesture {
    guard item.controlStyle == .disclosure, item.isEnabled else { return }
    isOn.toggle()
}
```

`.switch` 样式的行保留现状（由 Toggle 自己处理手势，避免冲突）。

### 6.3 `PluginPanelDetailView` 控件分支

```swift
switch control.kind {
case .segmented:
    // 现状，不改
case .datePicker:
    // 现状，不改
case .selectList:
    SelectListControl(
        control: control,
        onSelect: { optionID in
            onSelectionChange(control.id, optionID)
        }
    )
}
```

### 6.4 `SelectListControl` 组件

文件私有新增，位于 `MenuBarContent.swift`：

```swift
private struct SelectListControl: View {
    let control: PluginPanelControl
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = control.sectionTitle {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.bottom, 2)
            }

            VStack(spacing: 0) {
                ForEach(control.options) { option in
                    SelectListRow(
                        title: option.title,
                        isSelected: option.id == control.selectedOptionID,
                        isEnabled: control.isEnabled,
                        action: { onSelect(option.id) }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SelectListRow: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.primary.opacity(0.06) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }
}
```

### 6.5 视觉规范

- 列表行高 ≈ 24pt，悬停高亮用 6% 主色（`Color.primary.opacity(0.06)`）
- Section 标题 11pt `.secondary`，与现有 detail 区排版一致
- 多显示器 section 间由 `PluginPanelDetailView` 的 `VStack spacing: 10` 天然分隔
- checkmark 槽位固定宽度 14pt，未选中项占位保持左对齐一致

## 7. 错误处理与边界

| 场景 | 落地方式 |
|---|---|
| `listConnectedDisplays` 空 | `panelState` 返回 `isEnabled: false`，subtitle = `"未检测到可用显示器"` |
| `listAvailableResolutions` 返回 `[]` | 该显示器的 section 整个跳过（不画空 section） |
| `CGDisplayCopyAllDisplayModes` 返回 nil | `AppLog.displayResolutionController` 记 error，返回 `[]` |
| `applyResolution` 前 `modeId` 失效 | `.failure(.modeNotFound)`，设置 `lastErrorMessage`，UI 在行 description 红字显示 |
| `CGBeginDisplayConfiguration` 失败 | `.failure(.beginConfigFailed)`，**不调** Cancel |
| `CGConfigureDisplayWithDisplayMode` 失败 | **先调** `CGCancelDisplayConfiguration`，再返回 `.failure(.configureFailed)` |
| `CGCompleteDisplayConfiguration` 失败 | `.failure(.completeFailed)`，不再 Cancel（事务已半提交） |
| 切换成功 | 清除 `lastErrorMessage`，plugin 调 `onStateChange?()` 触发 `PluginHost.rebuildDerivedState` |
| 镜像副屏 | `listConnectedDisplays` 阶段过滤 |
| 虚拟/Dummy/DisplayLink | 依赖 `isUsableForDesktopGUI` + Safe flag 过滤绝大多数；MVP 不做 vendorID 黑名单 |
| 用户重复快速点击 | Controller 无状态，重复调用幂等 |

### 7.1 日志

`Sources/Core/Diagnostics/AppLog.swift` 新增：

```swift
extension AppLog {
    static let displayResolutionPlugin = Logger(
        subsystem: subsystem,
        category: "display-resolution-plugin"
    )
    static let displayResolutionController = Logger(
        subsystem: subsystem,
        category: "display-resolution-controller"
    )
}
```

记录点：
- 枚举失败（`CopyAllDisplayModes` nil）：error 级
- 切换开始：info 级，带目标 `width×height@modeId`
- 切换失败：error 级，带 `CGError.rawValue`
- 切换成功：info 级

### 7.2 线程

全部 `@MainActor`，符合 CoreGraphics / AppKit 要求，不引入 async/await。

## 8. 测试计划

### 8.1 单元测试

**前提**：项目当前没有 XCTest target，需要在 `project.yml` 新增 `MacToolsTests` target。

测试对象限定为纯函数逻辑，不触碰 CoreGraphics：

| 测试用例 | 覆盖对象 | 输入/断言 |
|---|---|---|
| `test_parseDisplayID_validPrefix` | `DisplayResolutionPlugin.parseDisplayID` | `"display.1"` → `1` |
| `test_parseDisplayID_invalidFormat` | 同上 | `"display.abc"` → `nil` |
| `test_parseDisplayID_wrongPrefix` | 同上 | `"foo.1"` → `nil` |
| `test_optionTitle_native` | `DisplayResolutionPlugin.optionTitle` | `isNative=true` → `"3008×1692 (原生)"` |
| `test_optionTitle_default` | 同上 | `isDefault=true, isNative=false` → `"3008×1692 (默认)"` |
| `test_optionTitle_scaled` | 同上 | 两 flag 都假 → `"3008×1692"` |
| `test_filterSameAspectRatio_dropsOffRatio` | `DisplayResolutionPlugin.filterSameAspectRatio` | 混合 16:9 和 16:10 → 只保留 native 同比项 |
| `test_filterSameAspectRatio_emptyInput` | 同上 | `[]` → `[]` |
| `test_DisplayResolutionInfo_equatable_byModeId` | `DisplayResolutionInfo.==` | 同 modeId 不同宽高 → 相等 |

`optionTitle` / `filterSameAspectRatio` / `parseDisplayID` 设为 `internal static` 方法，测试目标通过 `@testable import MacTools` 访问。

### 8.2 手动验证清单

1. **单屏内建 MacBook Retina**：
   - [ ] 插件行显示主屏当前分辨率
   - [ ] 点击展开，列表项数量 ≥ 3
   - [ ] 当前项有 checkmark
   - [ ] 选中其他项，屏幕切换 ≈ 1s，成功后 checkmark 跳转
   - [ ] Log 中看到成功记录
2. **外接 5K LG UltraFine**：
   - [ ] native 5120×2880 行存在
   - [ ] 多个 HiDPI 行存在（1920×1080、2560×1440 等）
   - [ ] 同宽高比过滤：无 16:10 异形模式
3. **多屏**：
   - [ ] 两屏都有独立 section，标题是显示器名称
   - [ ] 切换副屏不影响主屏
4. **镜像模式**：
   - [ ] 镜像副屏不出现在列表中
5. **热插拔**：
   - [ ] 插件打开后拔掉外接屏，再次打开菜单栏，副屏 section 消失
   - [ ] 重新插入，副屏 section 重新出现
6. **重启持久化**：
   - [ ] 切换分辨率 → 重启 → 分辨率保持
7. **错误路径**：
   - [ ] 开菜单 → 拔外接屏 → 未关菜单就点该屏某项 → log 错误，UI 不崩溃，error 行红字显示

### 8.3 构建验证

```sh
make build
```

Swift 6 严格并发检查下，`@MainActor` 标注覆盖所有 CG 调用路径，不应出现 concurrency 警告。

## 9. 权限与构建

- **无 entitlement 要求**：全部公开 API
- **沙盒应用 OK**
- **不需要辅助功能 / 屏幕录制权限**
- **链接 CoreGraphics.framework**：macOS target 自动链接，无需 project.yml 改动

## 10. 已知风险与未来扩展

### 10.1 已知坑位（实现时注意）

1. `ioFlags` 常量无 Swift 桥接，硬编码在 `DisplayModeFlags`
2. `kCGDisplayShowDuplicateLowResolutionModes` 不能省，省了会丢 LoDPI 原生模式行
3. 按 `(tag, width, height)` 分组，不能直接按 `(width, height)`，否则 native 5120×2880 和 HiDPI 同逻辑尺寸互相覆盖
4. `CGDisplayMode` 生命周期不归 ARC 管，只保存 `ioDisplayModeID`
5. 刷新率不参与身份，但分组时主动折叠到最高刷新率
6. 镜像拓扑不由本插件管理，如果未来要同步改镜像组需额外循环
7. `.permanently` 写系统偏好，用户下次插相同显示器会记得——这是预期行为

### 10.2 非 MVP 的未来扩展

- 刷新率切换（ProMotion 显示器、外接高刷新率显示器）
- `.forSession` 临时切换选项
- 快捷键（循环切换同显示器的分辨率）
- `CGDisplayRegisterReconfigurationCallback` 动态刷新
- 镜像拓扑管理
- 色彩配置 / HDR / 亮度
