# 显示器分辨率插件 · 侧滑布局设计文档

- **日期**：2026-04-15
- **目标版本**：MacTools 0.3.0
- **作者**：brainstorming session

## 1. 背景

当前「显示器分辨率」插件采用单层展开：点击插件行后，直接在主卡片内部纵向展示某个显示器的全部分辨率列表。

这个方案有两个问题：

- 主界面会被长分辨率列表明显撑高，干扰其他插件区块
- 用户的真实操作层级其实是两层：
  1. 先选显示器
  2. 再选该显示器的分辨率

因此本次改为双层导航布局：主卡片只负责显示显示器列表，分辨率列表通过右侧侧滑子面板展示，不再占用主卡片的纵向空间。

## 2. 目标

- 点击「显示器分辨率」后，主卡片内只显示显示器列表
- 点击某个显示器项，在主卡片右侧滑出独立子面板，显示该显示器的分辨率列表
- 子面板不改变主卡片宽度，不把主界面纵向撑高
- 维持现有插件整体 disclosure 行为：仍由标题行控制展开/收起
- 保持现有分辨率枚举、模式标签、错误提示与切换逻辑

## 3. 非目标

- 不改分辨率枚举算法
- 不改 `CGCompleteDisplayConfiguration(.permanently)` 的持久化语义
- 不增加刷新率切换
- 不增加快捷键
- 不把整个菜单改成多窗口或独立 popover

## 4. 交互设计

### 4.1 一级：插件展开

- 用户点击「显示器分辨率」标题行
- 插件进入 `isExpanded = true`
- 主卡片 detail 区显示“显示器列表”
- 此时右侧分辨率子面板默认不显示

### 4.2 二级：显示器选择

- 用户点击某个显示器项
- 若当前没有选中显示器：
  - 设置 `selectedDisplayID = 该显示器`
  - 右侧滑出该显示器的分辨率子面板
- 若当前选中的就是同一个显示器：
  - 视为 toggle 行为
  - 清空 `selectedDisplayID`
  - 右侧子面板收起
- 若当前选中的是另一个显示器：
  - 更新 `selectedDisplayID`
  - 子面板内容切换到新的显示器

### 4.3 插件收起

- 用户再次点击插件标题行，或菜单关闭
- 插件进入 `isExpanded = false`
- 同时清空 `selectedDisplayID`
- 主卡片 detail 和右侧子面板一起消失

## 5. 布局设计

### 5.1 主卡片

主卡片 detail 区不再直接展示分辨率列表，而是展示一个简洁的显示器导航列表：

- 每个显示器一行
- 行内容：
  - 显示器名称
  - 当前分辨率摘要
- 当前正在右侧展开的显示器项，用轻量选中态高亮

### 5.2 右侧子面板

右侧子面板为附着在主卡片右侧的浮出层：

- 默认隐藏
- 选中显示器后从右侧出现
- 视觉上与主卡片同属一个交互组，但不参与主卡片内部纵向排版
- 宽度固定，优先保证分辨率列表可读性

子面板内容：

- 顶部：当前显示器名称
- 下方：该显示器的分辨率列表
- 列表保留现有行为：
  - 当前项有 checkmark
  - 当前项不可重复触发
  - 点击其他项立即切换
  - 切换失败时在主插件 description 区显示红字错误

## 6. 状态模型

在现有 `isExpanded` 基础上，新增一个局部导航状态：

```swift
private var isExpanded: Bool = false
private var selectedDisplayID: CGDirectDisplayID?
private var lastErrorMessage: String?
```

状态约束：

- `isExpanded == false` 时，`selectedDisplayID` 必须为 `nil`
- `selectedDisplayID != nil` 时，必须对应当前仍存在于 `listConnectedDisplays()` 的显示器
- 若菜单展开后显示器热插拔导致 `selectedDisplayID` 失效：
  - 在下一次 `panelState` 计算时自动清空
  - 右侧子面板收起

## 7. 插件输出模型调整

当前 `PluginPanelDetail` 只适合纵向控件堆叠，无法直接表达“左侧导航 + 右侧子面板”。

本次设计建议对插件 detail 输出做最小扩展，引入双区域结构，而不是继续滥用单列 controls：

```swift
struct PluginPanelDetail {
    let primaryControls: [PluginPanelControl]
    let secondaryPanel: PluginPanelSecondaryPanel?
}

struct PluginPanelSecondaryPanel {
    let title: String
    let controls: [PluginPanelControl]
}
```

说明：

- `primaryControls`
  - 主卡片内部正常显示
  - 对该插件来说就是“显示器列表”
- `secondaryPanel`
  - 右侧侧滑子面板内容
  - nil 表示当前无选中显示器，不显示侧面板

这比继续往 `PluginPanelControl` 上堆更多字段更清晰，也更适合未来出现其他“主导航 + 次级面板”型插件。

## 8. 新增控件类型

显示器列表不是“分辨率选择列表”，它是一个导航列表。因此不应继续复用当前 `.selectList` 语义。

新增一个导航型控件：

```swift
enum PluginPanelControlKind {
    case segmented
    case datePicker
    case selectList
    case navigationList
}
```

语义区别：

- `selectList`
  - 点击即执行选择动作
  - 用于右侧分辨率列表
- `navigationList`
  - 点击只改变局部导航状态
  - 用于左侧显示器列表

## 9. UI 渲染设计

### 9.1 主卡片 detail

`PluginPanelDetailView` 改为两层：

- 左侧渲染 `primaryControls`
- 若 `secondaryPanel != nil`：
  - 在 detail 容器右侧渲染 `SecondarySlidingPanel`

### 9.2 右侧子面板容器

新增私有视图：

```swift
private struct SecondarySlidingPanel: View {
    let title: String
    let controls: [PluginPanelControl]
}
```

职责：

- 呈现右侧独立面板容器
- 负责标题区与内容区排版
- 负责入场/切换动画

### 9.3 动画

保持最小但明确的动效：

- 选中显示器时：右侧子面板从 trailing 方向轻微滑入
- 切换显示器时：内容交叉淡入切换，不整块闪烁
- 收起时：子面板淡出并向右偏移消失

## 10. `DisplayResolutionPlugin` 设计调整

### 10.1 主体输出

展开后：

- `primaryControls`：显示器导航列表
- `secondaryPanel`：
  - 若 `selectedDisplayID == nil`：为 `nil`
  - 若有值：输出该显示器对应的分辨率 `selectList`

### 10.2 Action 处理

现有 `.setSelection` 只够表达“分辨率选择”，不够表达“显示器导航切换”。

新增动作：

```swift
enum PluginPanelAction {
    case setSwitch(Bool)
    case setDisclosureExpanded(Bool)
    case setSelection(controlID: String, optionID: String)
    case setNavigationSelection(controlID: String, optionID: String)
    case setDate(controlID: String, value: Date)
}
```

约束：

- 左侧显示器列表使用 `.setNavigationSelection`
- 右侧分辨率列表继续使用 `.setSelection`

## 11. 测试计划

### 11.1 单元测试

新增覆盖：

- 选中显示器后，`secondaryPanel` 出现
- 再点同一显示器后，`secondaryPanel` 消失
- 切换到另一显示器后，`secondaryPanel.title` 正确切换
- 收起插件时，`selectedDisplayID` 被清空
- 显示器热插拔导致 `selectedDisplayID` 失效时，自动回退到无侧面板状态

### 11.2 手动验证

- 展开插件后，主卡片内只显示显示器列表，不直接出现分辨率长列表
- 点击某个显示器后，右侧出现分辨率面板
- 主卡片宽度与纵向高度基本稳定
- 点击同一显示器，右侧面板收起
- 点击另一显示器，右侧内容切换而不是堆叠
- 收起插件后，右侧面板同步消失

## 12. 风险与取舍

- 这是一次 UI 模型扩展，不再是纯插件内部改动
- 但如果不在 detail 层引入“secondary panel”概念，就只能继续把二级导航硬塞进纵向控件列表，后续会越来越乱
- 因此本次接受一个受控的共享 UI 模型扩展，换取清晰的二级导航结构

## 13. 结论

本次布局改动的核心不是“把分辨率列表换个样式”，而是把交互从单层选择器改为二级导航：

1. 插件展开
2. 选择显示器
3. 在右侧子面板选择分辨率

这能解决主界面被长列表撑高的问题，也更符合用户真实操作路径。
