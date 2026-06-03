import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class EjectDiskPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        EjectDiskPluginProvider()
    }
}

@MainActor
private struct EjectDiskPluginProvider: PluginProvider {
    func makePlugins() -> [any MacToolsPlugin] {
        [EjectDiskPlugin()]
    }
}

@MainActor
final class EjectDiskPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "eject-disk",
        title: "推出磁盘",
        iconName: "eject",
        iconTint: Color(nsColor: .systemGray),
        order: 92,
        defaultDescription: "推出所有可移动磁盘"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .keepPresented,
        buttonTitle: "推出"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EjectDiskPlugin")
    private var isEjecting = false
    private var ejectableDiskCount: Int = 0
    private var lastErrorMessage: String?
    private var volumeMountObservers: [NSObjectProtocol] = []

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: subtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: !isEjecting && ejectableDiskCount > 0,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        scheduleEjectableDiskCountRefresh()

        // 设置磁盘挂载/卸载事件监听
        setupVolumeMountObserver()
    }
    
    private func setupVolumeMountObserver() {
        // 如果已经设置了监听，就不再重复设置
        guard volumeMountObservers.isEmpty else { return }
        
        let workspace = NSWorkspace.shared
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        let mountObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForEjectableDiskAndUpdate()
            }
        }
        
        let unmountObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForEjectableDiskAndUpdate()
            }
        }
        
        volumeMountObservers.append(mountObserver)
        volumeMountObservers.append(unmountObserver)
    }
    
    private func checkForEjectableDiskAndUpdate() {
        scheduleEjectableDiskCountRefresh()
    }

    /// 把卷扫描放到后台线程，避免在慢速网络/可移动卷上阻塞主线程，扫完再回主线程更新计数。
    private func scheduleEjectableDiskCountRefresh() {
        Task.detached { [weak self] in
            let count = Self.ejectableDiskCountSync()
            await MainActor.run { self?.applyEjectableDiskCount(count) }
        }
    }

    private func applyEjectableDiskCount(_ count: Int) {
        guard ejectableDiskCount != count else { return }
        ejectableDiskCount = count
        onStateChange?()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            if controlID == "execute" {
                ejectAllDisks()
            }
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Private

    private var subtitle: String {
        if isEjecting { return "推出中..." }
        if ejectableDiskCount == 0 { return "无可推出的磁盘" }
        return "\(ejectableDiskCount) 个可推出的磁盘"
    }

    nonisolated private static func ejectableDiskCountSync() -> Int {
        let fileManager = FileManager.default
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EjectDiskPlugin")
        
        do {
            let volumesPath = "/Volumes"
            guard fileManager.fileExists(atPath: volumesPath) else {
                return 0
            }
            
            let ejectableVolumes = try getEjectableVolumes(from: volumesPath)
            logger.debug("Found \(ejectableVolumes.count) ejectable volumes")
            return ejectableVolumes.count
            
        } catch {
            logger.error("Failed to check ejectable disks: \(error)")
            return 0
        }
    }
    
    nonisolated static func getEjectableVolumes(from volumesPath: String) throws -> [String] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(atPath: volumesPath)
        
        return contents.filter { name in
            // 排除隐藏项
            if name.hasPrefix(".") {
                return false
            }
            
            // 通过卷资源属性判断可推出性，排除内部/不可移除卷
            let volumeURL = URL(fileURLWithPath: "\(volumesPath)/\(name)")
            guard let values = try? volumeURL.resourceValues(forKeys: [
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsInternalKey
            ]) else {
                return false
            }

            // 始终排除内部卷
            if values.volumeIsInternal == true {
                return false
            }

            // 仅保留可移除或可推出的卷
            return values.volumeIsRemovable == true || values.volumeIsEjectable == true
        }
    }

    private func ejectAllDisks() {
        guard !isEjecting else { return }

        isEjecting = true
        lastErrorMessage = nil
        onStateChange?()

        Task {
            do {
                try await executeEjectAll()

                await MainActor.run {
                    isEjecting = false
                    lastErrorMessage = nil
                    onStateChange?()
                }
            } catch {
                let errorMessage = error.localizedDescription
                logger.error("Failed to eject disks: \(errorMessage)")

                await MainActor.run {
                    isEjecting = false
                    lastErrorMessage = errorMessage
                    onStateChange?()
                }
            }
        }
    }

    private func executeEjectAll() async throws {
        let fileManager = FileManager.default
        let volumesPath = "/Volumes"
        
        guard fileManager.fileExists(atPath: volumesPath) else {
            throw NSError(domain: "EjectDiskPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "/Volumes 目录不可用"])
        }
        
        let ejectableVolumes = try await Task.detached {
            try Self.getEjectableVolumes(from: volumesPath)
        }.value
        
        guard !ejectableVolumes.isEmpty else {
            throw NSError(domain: "EjectDiskPlugin", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到可推出的磁盘"])
        }
        
        var successCount = 0
        var errorMessages: [String] = []
        
        for volumeName in ejectableVolumes {
            let volumePath = "\(volumesPath)/\(volumeName)"
            
            do {
                try await ejectVolume(at: volumePath)
                successCount += 1
                logger.info("Successfully ejected volume: \(volumeName)")
            } catch {
                errorMessages.append("- \(volumeName): \(error.localizedDescription)")
                logger.error("Failed to eject volume '\(volumeName)': \(error.localizedDescription)")
            }
        }
        
        // 如果有错误，抛出异常
        if !errorMessages.isEmpty {
            let message = "已推出 \(successCount) 个磁盘，\(errorMessages.count) 个失败:\n\(errorMessages.joined(separator: "\n"))"
            throw NSError(domain: "EjectDiskPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func ejectVolume(at volumePath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", volumePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorMessage = output.isEmpty ? "推出失败" : output
            throw NSError(domain: "EjectDiskPlugin", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
}
