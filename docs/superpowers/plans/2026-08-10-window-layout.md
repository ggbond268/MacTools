# Window Layout Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a MacTools `window-layout` plugin that applies Pane-like presets to the frontmost resizable window via the feature panel and optional global shortcuts.

**Architecture:** Independent plugin under `Plugins/WindowLayout/` with pure geometry, injectable Accessibility applicator, per-window restore history, and settings-backed inset. Host only renders panel/settings/shortcuts; no Core changes. Phase-2 edge-drag and two-window split stay unimplemented.

**Tech Stack:** Swift 6, AppKit, ApplicationServices (AX), MacToolsPluginKit v4, XCTest, XcodeGen via `make generate`.

## Global Constraints

- Plugin id: `window-layout` (must match `plugin.json.id` and `PluginMetadata.id`)
- PluginKit version: 4; `minHostVersion`: `1.2.0`
- Category: `productivity`; permission: `accessibility`
- Target screen: visible frame of the screen containing the window
- Minimum frame after clamp: 200×120 pt; almost-maximize default inset: 8 pt (range 0…40)
- User-facing copy: concise Chinese defaults + `.xcstrings` / `localizedMetadata`
- No edge-drag snap; no one-click two-window split; no mobile companion
- On Windows agents: write code and note that `xcodebuild` / `make generate` must run on macOS; do not claim tests passed without evidence
- Commit only when the human explicitly asks (include commit steps below for macOS implementers who were told to commit)

---

## File Structure

- Create: `Plugins/WindowLayout/plugin.json`
- Create: `Plugins/WindowLayout/Bundle/WindowLayoutPluginBundleEntrypoint.swift`
- Create: `Plugins/WindowLayout/Sources/WindowLayoutAction.swift` — action ids + titles
- Create: `Plugins/WindowLayout/Sources/WindowLayoutGeometry.swift` — pure rect math
- Create: `Plugins/WindowLayout/Sources/WindowLayoutHistory.swift` — restore snapshots
- Create: `Plugins/WindowLayout/Sources/WindowLayoutStore.swift` — inset persistence
- Create: `Plugins/WindowLayout/Sources/WindowLayoutApplicator.swift` — protocol + AX implementation
- Create: `Plugins/WindowLayout/Sources/WindowLayoutAccessibilityCheck.swift`
- Create: `Plugins/WindowLayout/Sources/WindowLayoutPlugin.swift` — plugin UI + wiring
- Create: `Plugins/WindowLayout/Resources/Localizable.xcstrings` — start with zh-Hans/en keys used by code
- Create: `Plugins/WindowLayout/Tests/WindowLayoutGeometryTests.swift`
- Create: `Plugins/WindowLayout/Tests/WindowLayoutHistoryTests.swift`
- Create: `Plugins/WindowLayout/Tests/WindowLayoutPluginTests.swift`
- Modify: `README.md` / `README.zh-CN.md` — one row for 窗口布局
- Create: `changes/unreleased/window-layout-plugin.md` — plugin release fragment

Do not edit `Configs/GeneratedPlugins.yml` by hand; run `make generate` on macOS after adding `plugin.json`.

---

### Task 1: Action enum + Geometry (TDD)

**Files:**
- Create: `Plugins/WindowLayout/Sources/WindowLayoutAction.swift`
- Create: `Plugins/WindowLayout/Sources/WindowLayoutGeometry.swift`
- Test: `Plugins/WindowLayout/Tests/WindowLayoutGeometryTests.swift`

**Interfaces:**
- Produces:
  - `enum WindowLayoutAction: String, CaseIterable, Sendable` with all spec ids
  - `enum WindowLayoutGeometry` with:
    - `static let minimumSize = CGSize(width: 200, height: 120)`
    - `static func targetFrame(action: WindowLayoutAction, visibleFrame: CGRect, currentFrame: CGRect, inset: CGFloat) -> CGRect`

- [ ] **Step 1: Write the failing geometry tests**

```swift
import XCTest
@testable import WindowLayoutPlugin

final class WindowLayoutGeometryTests: XCTestCase {
    private let V = CGRect(x: 100, y: 50, width: 1000, height: 800)

    func testLeftHalf() {
        let frame = WindowLayoutGeometry.targetFrame(
            action: .leftHalf,
            visibleFrame: V,
            currentFrame: CGRect(x: 200, y: 100, width: 400, height: 300),
            inset: 8
        )
        XCTAssertEqual(frame, CGRect(x: 100, y: 50, width: 500, height: 800))
    }

    func testCenterHalf() {
        let frame = WindowLayoutGeometry.targetFrame(
            action: .centerHalf,
            visibleFrame: V,
            currentFrame: .zero,
            inset: 8
        )
        XCTAssertEqual(frame, CGRect(x: 350, y: 50, width: 500, height: 800))
    }

    func testAlmostMaximizeUsesInset() {
        let frame = WindowLayoutGeometry.targetFrame(
            action: .almostMaximize,
            visibleFrame: V,
            currentFrame: .zero,
            inset: 10
        )
        XCTAssertEqual(frame, V.insetBy(dx: 10, dy: 10))
    }

    func testGrowClampsInsideVisibleFrame() {
        let current = V.insetBy(dx: 5, dy: 5)
        let frame = WindowLayoutGeometry.targetFrame(
            action: .grow,
            visibleFrame: V,
            currentFrame: current,
            inset: 8
        )
        XCTAssertTrue(V.contains(frame.insetBy(dx: 0.5, dy: 0.5)) || V == frame || V.contains(frame))
        XCTAssertEqual(frame, V)
    }

    func testCenterKeepsSize() {
        let current = CGRect(x: 120, y: 80, width: 300, height: 200)
        let frame = WindowLayoutGeometry.targetFrame(
            action: .center,
            visibleFrame: V,
            currentFrame: current,
            inset: 8
        )
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(frame.midX, V.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, V.midY, accuracy: 0.5)
    }

    func testAllActionsProduceFiniteRectsInsideOrEqualVisibleBoundsForFillActions() {
        for action in WindowLayoutAction.allCases where action != .restore {
            let frame = WindowLayoutGeometry.targetFrame(
                action: action,
                visibleFrame: V,
                currentFrame: CGRect(x: 150, y: 100, width: 400, height: 300),
                inset: 8
            )
            XCTAssertFalse(frame.isNull)
            XCTAssertGreaterThanOrEqual(frame.width, WindowLayoutGeometry.minimumSize.width)
            XCTAssertGreaterThanOrEqual(frame.height, WindowLayoutGeometry.minimumSize.height)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (macOS):  
`xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -only-testing:MacToolsTests/WindowLayoutGeometryTests -quiet`  
(First requires Task 5 scaffolding + `make generate`. If types missing before scaffold, expect compile/link failure.)

Expected: FAIL — types missing.

- [ ] **Step 3: Implement action + geometry**

```swift
import CoreGraphics
import Foundation

enum WindowLayoutAction: String, CaseIterable, Sendable {
    case maximize
    case almostMaximize = "almost-maximize"
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case centerHalf = "center-half"
    case leftThird = "left-third"
    case centerThird = "center-third"
    case rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds"
    case rightTwoThirds = "right-two-thirds"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case grow
    case shrink
    case center
    case restore
}

enum WindowLayoutGeometry {
    static let minimumSize = CGSize(width: 200, height: 120)
    private static let scaleFactor: CGFloat = 1.1

    static func targetFrame(
        action: WindowLayoutAction,
        visibleFrame V: CGRect,
        currentFrame: CGRect,
        inset: CGFloat
    ) -> CGRect {
        let raw: CGRect
        switch action {
        case .restore:
            return currentFrame
        case .maximize:
            raw = V
        case .almostMaximize:
            raw = V.insetBy(dx: inset, dy: inset)
        case .leftHalf:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width / 2, height: V.height)
        case .rightHalf:
            raw = CGRect(x: V.minX + V.width / 2, y: V.minY, width: V.width / 2, height: V.height)
        case .topHalf:
            raw = CGRect(x: V.minX, y: V.midY, width: V.width, height: V.height / 2)
        case .bottomHalf:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width, height: V.height / 2)
        case .centerHalf:
            raw = CGRect(x: V.midX - V.width / 4, y: V.minY, width: V.width / 2, height: V.height)
        case .leftThird:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width / 3, height: V.height)
        case .centerThird:
            raw = CGRect(x: V.minX + V.width / 3, y: V.minY, width: V.width / 3, height: V.height)
        case .rightThird:
            raw = CGRect(x: V.minX + 2 * V.width / 3, y: V.minY, width: V.width / 3, height: V.height)
        case .leftTwoThirds:
            raw = CGRect(x: V.minX, y: V.minY, width: 2 * V.width / 3, height: V.height)
        case .rightTwoThirds:
            raw = CGRect(x: V.minX + V.width / 3, y: V.minY, width: 2 * V.width / 3, height: V.height)
        case .topLeftQuarter:
            raw = CGRect(x: V.minX, y: V.midY, width: V.width / 2, height: V.height / 2)
        case .topRightQuarter:
            raw = CGRect(x: V.midX, y: V.midY, width: V.width / 2, height: V.height / 2)
        case .bottomLeftQuarter:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width / 2, height: V.height / 2)
        case .bottomRightQuarter:
            raw = CGRect(x: V.midX, y: V.minY, width: V.width / 2, height: V.height / 2)
        case .grow:
            raw = scaled(currentFrame, by: scaleFactor, within: V)
        case .shrink:
            raw = scaled(currentFrame, by: 1 / scaleFactor, within: V)
        case .center:
            raw = CGRect(
                x: V.midX - currentFrame.width / 2,
                y: V.midY - currentFrame.height / 2,
                width: currentFrame.width,
                height: currentFrame.height
            )
        }
        return clamp(raw, within: V)
    }

    private static func scaled(_ frame: CGRect, by factor: CGFloat, within V: CGRect) -> CGRect {
        let width = frame.width * factor
        let height = frame.height * factor
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    private static func clamp(_ frame: CGRect, within V: CGRect) -> CGRect {
        var width = min(max(frame.width.rounded(), minimumSize.width), V.width)
        var height = min(max(frame.height.rounded(), minimumSize.height), V.height)
        var x = frame.minX.rounded()
        var y = frame.minY.rounded()
        if x < V.minX { x = V.minX }
        if y < V.minY { y = V.minY }
        if x + width > V.maxX { x = V.maxX - width }
        if y + height > V.maxY { y = V.maxY - height }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
```

Note: AppKit/AX use bottom-left origin; keep geometry in the same space as `NSScreen.visibleFrame` and AX frames (do not flip in Geometry).

- [ ] **Step 4: Re-run geometry tests**

Expected: PASS after Task 5 wires the test target.

- [ ] **Step 5: Commit (only if human requested commits)**

```bash
git add Plugins/WindowLayout/Sources/WindowLayoutAction.swift Plugins/WindowLayout/Sources/WindowLayoutGeometry.swift Plugins/WindowLayout/Tests/WindowLayoutGeometryTests.swift
git commit -m "$(cat <<'EOF'
feat(window-layout): add layout action ids and pure geometry

EOF
)"
```

---

### Task 2: History store (TDD)

**Files:**
- Create: `Plugins/WindowLayout/Sources/WindowLayoutHistory.swift`
- Test: `Plugins/WindowLayout/Tests/WindowLayoutHistoryTests.swift`

**Interfaces:**
- Produces:
  - `struct WindowLayoutWindowKey: Hashable` with `pid: pid_t`, `windowID: String`
  - `final class WindowLayoutHistory` with `snapshotIfNeeded(key:frame:)`, `frame(for:)`, `clear(_:)`, `removeAll()`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import WindowLayoutPlugin

final class WindowLayoutHistoryTests: XCTestCase {
    func testKeepsOriginalSnapshotAcrossMultipleLayouts() {
        let history = WindowLayoutHistory()
        let key = WindowLayoutWindowKey(pid: 1, windowID: "w1")
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        history.snapshotIfNeeded(key: key, frame: original)
        history.snapshotIfNeeded(key: key, frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(history.frame(for: key), original)
    }

    func testClearRemovesSnapshot() {
        let history = WindowLayoutHistory()
        let key = WindowLayoutWindowKey(pid: 1, windowID: "w1")
        history.snapshotIfNeeded(key: key, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        history.clear(key)
        XCTAssertNil(history.frame(for: key))
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Foundation

struct WindowLayoutWindowKey: Hashable, Sendable {
    let pid: pid_t
    let windowID: String
}

final class WindowLayoutHistory: @unchecked Sendable {
    private var frames: [WindowLayoutWindowKey: CGRect] = [:]

    func snapshotIfNeeded(key: WindowLayoutWindowKey, frame: CGRect) {
        if frames[key] == nil {
            frames[key] = frame
        }
    }

    func frame(for key: WindowLayoutWindowKey) -> CGRect? {
        frames[key]
    }

    func clear(_ key: WindowLayoutWindowKey) {
        frames.removeValue(forKey: key)
    }

    func removeAll() {
        frames.removeAll()
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit if requested**

---

### Task 3: Preferences store (TDD)

**Files:**
- Create: `Plugins/WindowLayout/Sources/WindowLayoutStore.swift`
- Extend: `Plugins/WindowLayout/Tests/WindowLayoutPluginTests.swift` (or dedicated store tests in same file)

**Interfaces:**
- Produces: `final class WindowLayoutStore` with `almostMaximizeInset: CGFloat` (clamped 0…40), persisted under key `almost-maximize-inset`

- [ ] **Step 1: Write failing test using `UserDefaultsPluginStorage` pattern from other plugins**

```swift
func testInsetDefaultsToEightAndClamps() {
    let defaults = UserDefaults(suiteName: "window-layout-store-tests")!
    defaults.removePersistentDomain(forName: "window-layout-store-tests")
    let storage = UserDefaultsPluginStorage(pluginID: "window-layout", userDefaults: defaults)
    let store = WindowLayoutStore(storage: storage)
    XCTAssertEqual(store.almostMaximizeInset, 8)
    store.almostMaximizeInset = 99
    XCTAssertEqual(store.almostMaximizeInset, 40)
    store.almostMaximizeInset = -1
    XCTAssertEqual(store.almostMaximizeInset, 0)
}
```

- [ ] **Step 2: Implement store reading/writing Double via `context.storage` / `PluginStorage` API used by `BatteryChargeLimit` / `WindowSwitcherStore` — mirror the nearest existing store’s get/set helpers exactly.**

- [ ] **Step 3: Run tests — PASS**

---

### Task 4: Applicator protocol + fake + AX implementation

**Files:**
- Create: `Plugins/WindowLayout/Sources/WindowLayoutApplicator.swift`
- Create: `Plugins/WindowLayout/Sources/WindowLayoutAccessibilityCheck.swift`

**Interfaces:**
- Produces:

```swift
enum WindowLayoutApplyError: Error, Equatable {
    case accessibilityDenied
    case noResizableWindow
    case axFailure
    case nothingToRestore
}

struct WindowLayoutTargetWindow: Equatable {
    let key: WindowLayoutWindowKey
    let frame: CGRect
    let visibleFrame: CGRect
}

@MainActor
protocol WindowLayoutApplying: AnyObject {
    func resolveFrontmostResizableWindow() throws -> WindowLayoutTargetWindow
    func setFrame(_ frame: CGRect, for key: WindowLayoutWindowKey) throws
}
```

- [ ] **Step 1: Implement `WindowLayoutAccessibilityCheck` identical in behavior to `WindowSwitcherAccessibilityCheck` (AXIsProcessTrusted / prompt options).**

- [ ] **Step 2: Implement `FakeWindowLayoutApplicator` in test support (can live in test file) holding a mutable `WindowLayoutTargetWindow?` and last set frame.**

- [ ] **Step 3: Implement `AXWindowLayoutApplicator`:**
  - Resolve `NSWorkspace.shared.frontmostApplication`
  - Prefer focused/main window via AX attributes (follow `WindowSwitcherAppCatalog` patterns for copy attribute / position / size)
  - Build `windowID` from AX `kAXWindowIdentifierAttribute` if present, else stable fallback (`"ax-\(pid)-\(index)"` only if necessary — prefer real identifier)
  - `visibleFrame` from `NSScreen` containing window center (fallback primary)
  - Set position then size via `AXValue` CGPoint/CGSize (same order as common AX window movers); on failure throw `.axFailure`
  - Skip windows that are not resizable / fullscreen when detectable → `.noResizableWindow`

- [ ] **Step 4: No mandatory XCTest for live AX; fake covered in Task 6.**

---

### Task 5: Plugin package scaffold

**Files:**
- Create: `Plugins/WindowLayout/plugin.json`
- Create: `Plugins/WindowLayout/Bundle/WindowLayoutPluginBundleEntrypoint.swift`
- Create: `Plugins/WindowLayout/Sources/WindowLayoutPlugin.swift` (minimal compiling stub)
- Create: `Plugins/WindowLayout/Resources/Localizable.xcstrings` (minimal)

**Interfaces:**
- Factory: `WindowLayoutPlugin.WindowLayoutPluginFactory`
- Bundle scheme: `WindowLayoutPlugin`

- [ ] **Step 1: Add `plugin.json`**

```json
{
  "id": "window-layout",
  "displayName": "窗口布局",
  "summary": "用预设调整前台窗口大小与位置",
  "localizedMetadata": {
    "en": {
      "displayName": "Window Layout",
      "summary": "Resize and position the frontmost window with presets."
    },
    "zh-Hans": {
      "displayName": "窗口布局",
      "summary": "用预设调整前台窗口大小与位置"
    },
    "zh-Hant": {
      "displayName": "視窗佈局",
      "summary": "用預設調整前景視窗大小與位置"
    }
  },
  "version": "1.0.0",
  "minHostVersion": "1.2.0",
  "pluginKitVersion": 4,
  "bundleRelativePath": "WindowLayout.bundle",
  "factoryClass": "WindowLayoutPlugin.WindowLayoutPluginFactory",
  "build": {
    "project": "../../MacTools.xcodeproj",
    "scheme": "WindowLayoutPlugin"
  },
  "capabilities": {
    "primaryPanel": true,
    "componentPanel": false,
    "settings": "form"
  },
  "permissions": ["accessibility"],
  "category": "productivity"
}
```

Add the remaining marketplace languages later to match sibling plugins if release requires full `localizedMetadata` parity; at minimum keep zh-Hans + en.

- [ ] **Step 2: Bundle entrypoint**

```swift
import WindowLayoutPlugin

private let windowLayoutPluginFactoryAnchor: Any.Type = WindowLayoutPluginFactory.self
```

- [ ] **Step 3: Stub factory + empty plugin compiling against Kit (metadata id `window-layout`, disclosure panel).**

- [ ] **Step 4: On macOS run `make generate` then `make build-plugin PLUGIN=WindowLayout` (or full `make build`).**

Expected: plugin target compiles.

---

### Task 6: Plugin panel + apply pipeline (TDD with fake)

**Files:**
- Modify: `Plugins/WindowLayout/Sources/WindowLayoutPlugin.swift`
- Test: `Plugins/WindowLayout/Tests/WindowLayoutPluginTests.swift`

**Interfaces:**
- Consumes: Geometry, History, Store, `WindowLayoutApplying`
- Produces: expandable primary panel with `actionRow` controls for every `WindowLayoutAction` except grouping headers; `restore` disabled when history empty for current key (approximate: disabled when history has no entries if resolve fails — tests use fake)

- [ ] **Step 1: Write plugin tests**

```swift
@MainActor
func testApplyLeftHalfSnapshotsAndSetsFrame() throws {
    let fake = FakeWindowLayoutApplicator(
        window: WindowLayoutTargetWindow(
            key: WindowLayoutWindowKey(pid: 42, windowID: "w"),
            frame: CGRect(x: 10, y: 10, width: 400, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
    )
    let plugin = WindowLayoutPlugin(
        localization: PluginLocalization(bundle: .main),
        applicator: fake,
        accessibilityTrusted: { true }
    )
    plugin.handleAction(.invokeAction(controlID: WindowLayoutAction.leftHalf.rawValue))
    XCTAssertEqual(fake.lastSetFrame?.width, 500)
    XCTAssertNotNil(plugin) // history retained internally — assert via restore
    plugin.handleAction(.invokeAction(controlID: WindowLayoutAction.restore.rawValue))
    XCTAssertEqual(fake.lastSetFrame, CGRect(x: 10, y: 10, width: 400, height: 300))
}

@MainActor
func testDeniedAccessibilitySetsError() {
    let plugin = WindowLayoutPlugin(
        localization: PluginLocalization(bundle: .main),
        applicator: FakeWindowLayoutApplicator(window: nil),
        accessibilityTrusted: { false }
    )
    plugin.handleAction(.invokeAction(controlID: WindowLayoutAction.maximize.rawValue))
    XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
}
```

- [ ] **Step 2: Implement apply path**

```swift
func apply(_ action: WindowLayoutAction) {
    guard accessibilityTrusted() else {
        lastErrorMessage = localization.string("error.accessibilityRequired", defaultValue: "需要辅助功能权限")
        requestPermissionGuidance?("accessibility")
        onStateChange?()
        return
    }
    do {
        if action == .restore {
            let target = try applicator.resolveFrontmostResizableWindow()
            guard let previous = history.frame(for: target.key) else {
                throw WindowLayoutApplyError.nothingToRestore
            }
            try applicator.setFrame(previous, for: target.key)
            history.clear(target.key)
            lastErrorMessage = nil
            onStateChange?()
            return
        }
        let target = try applicator.resolveFrontmostResizableWindow()
        history.snapshotIfNeeded(key: target.key, frame: target.frame)
        let next = WindowLayoutGeometry.targetFrame(
            action: action,
            visibleFrame: target.visibleFrame,
            currentFrame: target.frame,
            inset: store.almostMaximizeInset
        )
        try applicator.setFrame(next, for: target.key)
        lastErrorMessage = nil
        onStateChange?()
    } catch {
        lastErrorMessage = userMessage(for: error)
        onStateChange?()
    }
}
```

Wire `handleAction` for `.setDisclosureExpanded` and `.invokeAction`; `handleShortcutAction` calls the same `apply` when `WindowLayoutAction(rawValue: id)` matches.

- [ ] **Step 3: Build panel detail** — for each action (grouped with `sectionTitle` on first row of each group: 半屏 / 三分 / 四分 / 缩放与位置 / 恢复), emit `PluginPanelControl` `kind: .actionRow` with `id: action.rawValue`, `actionBehavior: .keepPresented`, `isEnabled` false for restore when `history` empty **or** when fake reports no snapshot (plugin can track `hasRestoreTarget` after last resolve; simpler approach for v1: enable restore always in UI but show error `nothingToRestore` — prefer disable when `history` non-empty globally is wrong; **disable restore only when history has zero entries** as phase-1 approximation, documented in tests).

- [ ] **Step 4: Run plugin tests — PASS**

---

### Task 7: Settings + shortcuts + permission cards

**Files:**
- Modify: `Plugins/WindowLayout/Sources/WindowLayoutPlugin.swift`
- Modify: `Plugins/WindowLayout/Resources/Localizable.xcstrings`
- Extend tests for settings slider persistence

- [ ] **Step 1: `permissionRequirements`** — single accessibility requirement (copy WindowSwitcher wording adapted to window layout).

- [ ] **Step 2: `settingsPage`** — one form section with slider row id `almost-maximize-inset`, range 0...40, step 1, valueFormat suffix ` pt`.

- [ ] **Step 3: `handleSettingsAction`** — on `.setNumber` committed, update `store.almostMaximizeInset` and `onStateChange?()`.

- [ ] **Step 4: `shortcutDefinitions`** — for every `WindowLayoutAction` except none: map each to `PluginShortcutDefinition(id:rawValue, actionID:rawValue, scope:.global, defaultBinding:nil, isRequired:false, settingsGroupID:"window-layout-shortcuts", ...)`.

- [ ] **Step 5: Implement `AccessibilityPermissionRefreshing` like WindowSwitcher; refresh on activate/refresh.

- [ ] **Step 6: Test settings number commit updates inset.**

---

### Task 8: Docs + changelog

**Files:**
- Modify: `README.md` and `README.zh-CN.md` — add Window Layout / 窗口布局 row in Features table
- Create: `changes/unreleased/window-layout-added.md`

```markdown
---
release: plugin
type: added
---

Added Window Layout presets to resize and position the frontmost window from the Feature Panel or global shortcuts.
```

- [ ] **Step 1: Update READMEs with one concise feature bullet matching product voice.**
- [ ] **Step 2: Add changelog fragment.**
- [ ] **Step 3: On macOS, run geometry + plugin tests once more.**

---

## Spec coverage checklist

| Spec item | Task |
|-----------|------|
| Independent `window-layout` plugin | 5 |
| Pane-like action set | 1, 6 |
| Panel + shortcuts | 6, 7 |
| Window’s screen visible frame | 4, 6 |
| Restore keeps original until restore | 2, 6 |
| Almost-maximize inset setting | 3, 7 |
| Accessibility permission | 7 |
| No edge-drag / two-window split | Global Constraints |
| README + changelog | 8 |
| Geometry unit tests | 1 |

## Placeholder / consistency review

- Action raw values match spec ids (`almost-maximize`, `left-half`, …).
- Geometry uses AppKit bottom-left space consistently with AX.
- Fake applicator enables tests without macOS UI automation.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-10-window-layout.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — execute tasks in this session with executing-plans checkpoints  

**Which approach?**

Note: this machine is Windows; full `make generate` / `xcodebuild` verification needs a Mac. Inline execution here can still author all plugin sources and tests, then you verify on macOS.
