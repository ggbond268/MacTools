import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

// MARK: - Factory

public final class FixDamagedAppPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        FixDamagedAppPluginProvider(context: context)
    }
}

@MainActor
private struct FixDamagedAppPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [FixDamagedAppPlugin(context: context)]
    }
}

// MARK: - Plugin

@MainActor
final class FixDamagedAppPlugin: MacToolsPlugin, PluginPrimaryPanel, DropZoneAnchorProviding {

    // MARK: Metadata

    let metadata = PluginMetadata(
        id: "fix-damaged-app",
        title: "修复损坏应用",
        iconName: "wrench.and.screwdriver.fill",
        iconTint: Color(nsColor: .systemOrange),
        order: 94,
        defaultDescription: "移除隔离属性，解决「已损坏」或「不受信任」提示"
    )

    // MARK: State

    private enum FixState: Equatable {
        case idle
        case running
        case success(appName: String)
        case failure(message: String)
    }

    private var selectedApp: URL?
    private var fixState: FixState = .idle

    // MARK: Drag Detection State

    private let storage: PluginStorage
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var dropZonePanel: FixDamagedAppDropZonePanel?
    private var isDragPanelShowing = false
    private var isMouseButtonDown = false
    /// 记录 mouseDown 时的拖拽剪贴板版本号，用于识别新拖拽会话
    private var dragSessionPasteboardChangeCount: Int = Int.min

    // MARK: DropZoneAnchorProviding

    var anchorRectProvider: (() -> NSRect?)?

    var isDragDetectionEnabled: Bool {
        storage.bool(forKey: StorageKey.isDragDetectionEnabled)
    }

    // MARK: Storage Keys

    private enum StorageKey {
        static let isDragDetectionEnabled = "drag-detection-enabled"
    }

    // MARK: MacToolsPlugin

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "FixDamagedAppPlugin"
    )

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    // MARK: Init

    init(context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "fix-damaged-app")) {
        self.storage = context.storage
    }

    // MARK: Lifecycle

    func activate(context: PluginRuntimeContext) {
        updateDragMonitoring()
    }

    func deactivate(reason: PluginDeactivationReason) {
        stopDragMonitoring()
        hideDropZonePanel()
    }

    func refresh() {}

    // MARK: Configuration

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [weak self] _ in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                FixDamagedAppSettingsView(
                    isDragDetectionEnabled: self.isDragDetectionEnabled,
                    onToggle: { [weak self] isOn in
                        self?.setDragDetectionEnabled(isOn)
                    }
                )
            )
        }
    }

    func setDragDetectionEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: StorageKey.isDragDetectionEnabled)
        updateDragMonitoring()
        onStateChange?()
    }

    // MARK: PluginPrimaryPanel

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .dismissBeforeHandling,
        buttonTitle: "选择"
    )

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: primarySubtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: fixState != .running,
            isVisible: true,
            detail: nil,
            errorMessage: primaryError
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case .invokeAction(let controlID):
            handleControlAction(controlID: controlID)
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    // MARK: Private

    private func handleControlAction(controlID: String) {
        switch controlID {
        case "execute":
            chooseApp()
        default:
            break
        }
    }

    private var primarySubtitle: String {
        switch fixState {
        case .idle:
            return selectedApp.map { $0.deletingPathExtension().lastPathComponent } ?? "选择 .app 文件以修复"
        case .running:
            return "修复中…"
        case .success(let name):
            return "已修复：\(name)"
        case .failure:
            return selectedApp.map { $0.deletingPathExtension().lastPathComponent } ?? "选择 .app 文件以修复"
        }
    }

    private var primaryError: String? {
        guard case .failure(let message) = fixState else { return nil }
        return message
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要修复的应用"
        panel.message = "选择显示「已损坏」或「不受信任」的应用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let appBundleType = UTType("com.apple.application-bundle") {
            panel.allowedContentTypes = [appBundleType]
        }
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        // canChooseDirectories 为 true 且 allowedContentTypes 无法阻止选中普通目录，
        // 因此与拖拽路径一致，必须校验是 .app，避免对任意目录执行管理员权限的 xattr 删除。
        guard url.pathExtension.lowercased() == "app" else {
            selectedApp = url
            fixState = .failure(message: "请选择 .app 应用")
            onStateChange?()
            return
        }
        selectedApp = url
        fixState = .idle
        onStateChange?()
        performFix()
    }

    private func performFix() {
        guard let appURL = selectedApp, fixState != .running else { return }
        let appPath = appURL.path
        let appName = appURL.deletingPathExtension().lastPathComponent
        fixState = .running
        onStateChange?()
        Task {
            do {
                try await Self.removeQuarantine(appPath: appPath)
                await MainActor.run {
                    self.fixState = .success(appName: appName)
                    self.onStateChange?()
                }
            } catch {
                let message = error.localizedDescription
                self.logger.error("Quarantine removal failed for '\(appPath)': \(message)")
                await MainActor.run {
                    self.fixState = .failure(message: message)
                    self.onStateChange?()
                }
            }
        }
    }

    private static func removeQuarantine(appPath: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try runQuarantineRemoval(appPath: appPath)
        }.value
    }

    // MARK: Private - Drag Monitoring

    private func updateDragMonitoring() {
        stopDragMonitoring()
        guard isDragDetectionEnabled else { return }
        startDragMonitoring()
    }

    private func startDragMonitoring() {
        // NSEvent 全局监听器在主线程触发，用 MainActor.assumeIsolated 同步执行，
        // 避免 Task 异步入队导致多个事件同时通过 isDragPanelShowing 检查
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMouseButtonDown = true
                // 记录当前剪贴板版本，后续仅在 changeCount 变化时（真正开始拖拽）才响应
                self?.dragSessionPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
            }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleGlobalDrag()
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMouseButtonDown = false
                self?.handleGlobalMouseUp()
            }
        }
    }

    private func stopDragMonitoring() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        isMouseButtonDown = false
    }

    private func handleGlobalDrag() {
        guard !isDragPanelShowing, isMouseButtonDown else { return }
        let pb = NSPasteboard(name: .drag)
        // 仅当拖拽剪贴板在本次 mouseDown 之后发生了变化时才响应，
        // 防止残留的旧剪贴板数据在普通点击（如打开访达）时误触发
        guard pb.changeCount != dragSessionPasteboardChangeCount else { return }
        guard
            let urls = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            urls.contains(where: { $0.pathExtension.lowercased() == "app" })
        else { return }
        showDropZonePanel()
    }

    private func handleGlobalMouseUp() {
        guard isDragPanelShowing else { return }
        // 若松手位置在面板范围内，说明文件投入了窗口，不关闭——交由 drop 流程处理
        // 全局 mouseUp 比 SwiftUI onDrop 更早触发，不能依赖 isDropPending 此时已被设置
        if let panel = dropZonePanel, panel.frame.contains(NSEvent.mouseLocation) { return }
        dropZonePanel?.dismissIfIdle()
    }

    private func showDropZonePanel() {
        isDragPanelShowing = true
        let vm = DropZoneViewModel(
            onComplete: { [weak self] appName, succeeded, errorMessage in
                guard let self else { return }
                if succeeded {
                    self.fixState = .success(appName: appName)
                } else {
                    self.fixState = .failure(message: errorMessage ?? "修复失败")
                }
                self.onStateChange?()
            },
            onDismiss: { [weak self] in
                self?.hideDropZonePanel()
            }
        )
        let panel = FixDamagedAppDropZonePanel(viewModel: vm)
        positionDropZonePanel(panel)
        panel.makeKeyAndOrderFront(nil)
        dropZonePanel = panel
    }

    private func hideDropZonePanel() {
        dropZonePanel?.orderOut(nil)
        dropZonePanel = nil
        isDragPanelShowing = false
    }

    private func positionDropZonePanel(_ panel: NSPanel) {
        let panelSize = panel.frame.size

        // 优先锚定在 App 状态栏图标正下方
        if let anchorRect = anchorRectProvider?() {
            let screenMaxX = NSScreen.main?.frame.maxX ?? 1440
            let rawX = anchorRect.midX - panelSize.width / 2
            let x = max(8, min(rawX, screenMaxX - panelSize.width - 8))
            let y = anchorRect.minY - panelSize.height - 4
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        // 回退：屏幕顶部居中
        guard let screen = NSScreen.main else { return }
        let menuBarThickness = NSStatusBar.system.thickness
        let x = screen.frame.midX - panelSize.width / 2
        let y = screen.frame.maxY - menuBarThickness - panelSize.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Quarantine Removal (nonisolated helper)

func runQuarantineRemoval(appPath: String) throws {
    // Reject paths containing double-quote to prevent AppleScript string literal injection
    guard !appPath.contains("\"") else {
        throw NSError(
            domain: "FixDamagedAppPlugin",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "应用路径包含不支持的字符（双引号）"]
        )
    }
    // Use AppleScript's `quoted form of` to safely quote the path in the shell command
    let script = """
    set appPath to "\(appPath)"
    do shell script "xattr -r -d com.apple.quarantine " & quoted form of appPath with administrator privileges
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if errMsg.contains("-128") || errMsg.contains("User canceled") {
            throw NSError(
                domain: "FixDamagedAppPlugin",
                code: -128,
                userInfo: [NSLocalizedDescriptionKey: "用户取消了授权"]
            )
        }
        throw NSError(
            domain: "FixDamagedAppPlugin",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: errMsg.isEmpty ? "修复失败（未知错误）" : errMsg]
        )
    }
}


