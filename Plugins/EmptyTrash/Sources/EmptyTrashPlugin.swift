import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class EmptyTrashPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        EmptyTrashPluginProvider()
    }
}

@MainActor
private struct EmptyTrashPluginProvider: PluginProvider {
    func makePlugins() -> [any MacToolsPlugin] {
        [EmptyTrashPlugin()]
    }
}

final class EmptyTrashPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "empty-trash",
        title: "清空废纸篓",
        iconName: "trash",
        iconTint: Color(nsColor: .systemGray),
        order: 93,
        defaultDescription: "清空废纸篓中的所有项目"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .keepPresented,
        buttonTitle: "清空"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EmptyTrashPlugin")
    private var itemCount: Int = 0
    private var isEmptying = false
    private var lastErrorMessage: String?

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: subtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: !isEmptying && itemCount > 0,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        Task { @MainActor in
            scheduleCountRefresh()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        Task { @MainActor in
            switch action {
            case let .invokeAction(controlID):
                if controlID == "execute" {
                    emptyTrash()
                }
            default:
                break
            }
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Private

    @MainActor
    private func scheduleCountRefresh() {
        Task {
            let count = await Self.fetchTrashItemCount()
            await MainActor.run {
                if self.itemCount != count {
                    self.itemCount = count
                    self.onStateChange?()
                }
            }
        }
    }

    private var subtitle: String {
        if isEmptying { return "清空中..." }
        if itemCount == 0 { return "废纸篓为空" }
        return "\(itemCount) 个项目"
    }

    @MainActor
    private func emptyTrash() {
        guard !isEmptying, itemCount > 0 else { return }
        isEmptying = true
        lastErrorMessage = nil
        onStateChange?()

        Task {
            do {
                try await Self.emptyTrashViaAppleScript()
                await MainActor.run {
                    self.isEmptying = false
                    self.itemCount = 0
                    self.onStateChange?()
                    self.scheduleCountRefresh()
                }
            } catch {
                await MainActor.run {
                    self.isEmptying = false
                    self.lastErrorMessage = error.localizedDescription
                    self.onStateChange?()
                    self.scheduleCountRefresh()
                    self.logger.error("Empty trash failed: \(error)")
                }
            }
        }
    }

    // MARK: - AppleScript helpers

    private static func fetchTrashItemCount() async -> Int {
        let script = "tell application \"Finder\" to count items of trash"
        return await Task.detached(priority: .userInitiated) {
            let result = runOsascriptStandalone(script)
            guard result.exitCode == 0 else { return 0 }
            return Int(result.output) ?? 0
        }.value
    }

    private static func emptyTrashViaAppleScript() async throws {
        let script = "tell application \"Finder\" to empty trash"
        try await Task.detached(priority: .userInitiated) {
            let result = runOsascriptStandalone(script)
            guard result.exitCode == 0 else {
                throw NSError(
                    domain: "EmptyTrashPlugin",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: emptyTrashFailureMessage(stderr: result.errorOutput)]
                )
            }
        }.value
    }

    /// Distinguishes an Automation-permission denial (so the user can fix it) from
    /// other Finder failures, instead of always blaming the permission.
    nonisolated static func emptyTrashFailureMessage(stderr: String) -> String {
        if stderr.contains("-1743") || stderr.contains("-1744") {
            return "需要自动化权限：请在 系统设置 › 隐私与安全性 › 自动化 中允许 MacTools 控制“访达”后重试。"
        }
        return "清空废纸篓失败"
    }
}

private struct OsascriptResult {
    let exitCode: Int32
    let output: String
    let errorOutput: String
}

private func runOsascriptStandalone(_ script: String) -> OsascriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        // Drain both pipes before waiting to avoid deadlock on large output.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return OsascriptResult(exitCode: process.terminationStatus, output: output, errorOutput: errorOutput)
    } catch {
        return OsascriptResult(exitCode: -1, output: "", errorOutput: error.localizedDescription)
    }
}
