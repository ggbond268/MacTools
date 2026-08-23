import Foundation
import OSLog
import MacToolsPluginKit

@MainActor
protocol SystemSoftRestartRunning: AnyObject {
    var isAvailable: Bool { get }
    var isRunning: Bool { get }

    func run(
        plan: SystemSoftRestartPlan,
        onEvent: @escaping @MainActor (SystemSoftRestartEvent) -> Void
    ) async throws -> SystemSoftRestartResult
}

private struct SystemSoftRestartOutputSnapshot: Sendable {
    let events: [SystemSoftRestartEvent]
    let standardError: String
}

private final class SystemSoftRestartOutputCollector: @unchecked Sendable {
    private static let maximumErrorBytes = 64 * 1024

    private let lock = NSLock()
    private var outputBuffer = Data()
    private var events: [SystemSoftRestartEvent] = []
    private var errorBuffer = Data()

    func appendOutput(_ data: Data) -> [SystemSoftRestartEvent] {
        guard !data.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        outputBuffer.append(data)
        return drainCompleteLines()
    }

    func appendError(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        let remainingCapacity = Self.maximumErrorBytes - errorBuffer.count
        guard remainingCapacity > 0 else { return }
        errorBuffer.append(data.prefix(remainingCapacity))
    }

    func finish(output: Data, error: Data) -> SystemSoftRestartOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }

        outputBuffer.append(output)
        _ = drainCompleteLines()
        decodeTrailingOutputIfPresent()

        let remainingCapacity = Self.maximumErrorBytes - errorBuffer.count
        if remainingCapacity > 0 {
            errorBuffer.append(error.prefix(remainingCapacity))
        }

        let errorText = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SystemSoftRestartOutputSnapshot(events: events, standardError: errorText)
    }

    private func drainCompleteLines() -> [SystemSoftRestartEvent] {
        var decodedEvents: [SystemSoftRestartEvent] = []
        let decoder = JSONDecoder()

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newlineIndex]
            outputBuffer.removeSubrange(...newlineIndex)

            guard !line.isEmpty,
                  let event = try? decoder.decode(SystemSoftRestartEvent.self, from: Data(line))
            else {
                continue
            }

            events.append(event)
            decodedEvents.append(event)
        }

        return decodedEvents
    }

    private func decodeTrailingOutputIfPresent() {
        guard !outputBuffer.isEmpty else { return }
        defer { outputBuffer.removeAll(keepingCapacity: false) }

        if let event = try? JSONDecoder().decode(SystemSoftRestartEvent.self, from: outputBuffer) {
            events.append(event)
        }
    }
}

@MainActor
final class SystemSoftRestartRunner: SystemSoftRestartRunning {
    private enum Timing {
        static let executionTimeout: Duration = .seconds(90)
    }

    private enum RunnerError: LocalizedError {
        case helperUnavailable(PluginLocalization)
        case requestPreparationFailed(String, PluginLocalization)
        case launchFailed(String, PluginLocalization)
        case helperFailed(String, PluginLocalization)
        case timedOut(PluginLocalization)

        var errorDescription: String? {
            switch self {
            case let .helperUnavailable(localization):
                return localization.string(
                    "error.helperUnavailable",
                    defaultValue: "当前插件包缺少系统软重启组件。"
                )
            case let .requestPreparationFailed(detail, localization):
                return localization.format(
                    "error.requestPreparationFailedFormat",
                    defaultValue: "无法准备软重启：%@",
                    detail
                )
            case let .launchFailed(detail, localization):
                return localization.format(
                    "error.launchFailedFormat",
                    defaultValue: "无法启动软重启组件：%@",
                    detail
                )
            case let .helperFailed(detail, localization):
                return localization.format(
                    "error.helperFailedFormat",
                    defaultValue: "系统软重启未完成：%@",
                    detail
                )
            case let .timedOut(localization):
                return localization.string(
                    "error.timedOut",
                    defaultValue: "系统软重启等待超时。部分用户服务可能仍在自动恢复。"
                )
            }
        }
    }

    private final class RunningHelper {
        let id: UUID
        let process: Process
        let standardOutput: Pipe
        let standardError: Pipe
        let collector: SystemSoftRestartOutputCollector
        let runDirectory: URL
        let onEvent: @MainActor (SystemSoftRestartEvent) -> Void
        let continuation: CheckedContinuation<SystemSoftRestartResult, Error>
        var timeoutTask: Task<Void, Never>?
        var didTimeOut = false

        init(
            id: UUID,
            process: Process,
            standardOutput: Pipe,
            standardError: Pipe,
            collector: SystemSoftRestartOutputCollector,
            runDirectory: URL,
            onEvent: @escaping @MainActor (SystemSoftRestartEvent) -> Void,
            continuation: CheckedContinuation<SystemSoftRestartResult, Error>
        ) {
            self.id = id
            self.process = process
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.collector = collector
            self.runDirectory = runDirectory
            self.onEvent = onEvent
            self.continuation = continuation
        }
    }

    var isAvailable: Bool {
        guard let helperURL else { return false }
        return fileManager.isExecutableFile(atPath: helperURL.path)
    }

    var isRunning: Bool {
        runningHelper?.process.isRunning == true
    }

    private let helperURL: URL?
    private let supportDirectory: URL
    private let temporaryDirectory: URL
    private let localization: PluginLocalization
    private let fileManager: FileManager
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SystemSoftRestartRunner"
    )
    private var runningHelper: RunningHelper?

    init(
        helperURL: URL?,
        supportDirectory: URL?,
        temporaryDirectory: URL?,
        localization: PluginLocalization,
        fileManager: FileManager = .default
    ) {
        self.helperURL = helperURL
        self.supportDirectory = supportDirectory
            ?? fileManager.temporaryDirectory.appendingPathComponent("MacTools-SystemSoftRestart-Support", isDirectory: true)
        self.temporaryDirectory = temporaryDirectory
            ?? fileManager.temporaryDirectory.appendingPathComponent("MacTools-SystemSoftRestart", isDirectory: true)
        self.localization = localization
        self.fileManager = fileManager
    }

    func run(
        plan: SystemSoftRestartPlan,
        onEvent: @escaping @MainActor (SystemSoftRestartEvent) -> Void
    ) async throws -> SystemSoftRestartResult {
        guard runningHelper == nil else {
            throw RunnerError.helperFailed(
                localization.string("error.alreadyRunning", defaultValue: "已有软重启正在进行。"),
                localization
            )
        }
        guard let helperURL, isAvailable else {
            throw RunnerError.helperUnavailable(localization)
        }

        let preparedRequest: (runDirectory: URL, requestURL: URL)
        do {
            preparedRequest = try prepareRequest(for: plan)
        } catch {
            throw RunnerError.requestPreparationFailed(error.localizedDescription, localization)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let collector = SystemSoftRestartOutputCollector()
            let runID = UUID()

            process.executableURL = helperURL
            process.arguments = ["--request", preparedRequest.requestURL.path]
            process.standardOutput = standardOutput
            process.standardError = standardError

            let runningHelper = RunningHelper(
                id: runID,
                process: process,
                standardOutput: standardOutput,
                standardError: standardError,
                collector: collector,
                runDirectory: preparedRequest.runDirectory,
                onEvent: onEvent,
                continuation: continuation
            )
            self.runningHelper = runningHelper

            standardOutput.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
                let data = fileHandle.availableData
                let events = collector.appendOutput(data)
                guard !events.isEmpty else { return }

                Task { @MainActor [weak self] in
                    self?.deliver(events: events, runID: runID)
                }
            }
            standardError.fileHandleForReading.readabilityHandler = { fileHandle in
                collector.appendError(fileHandle.availableData)
            }
            process.terminationHandler = { [weak self] terminatedProcess in
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil

                let remainingOutput = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let remainingError = standardError.fileHandleForReading.readDataToEndOfFile()
                let snapshot = collector.finish(output: remainingOutput, error: remainingError)
                let terminationStatus = terminatedProcess.terminationStatus

                Task { @MainActor [weak self] in
                    self?.finish(runID: runID, terminationStatus: terminationStatus, snapshot: snapshot)
                }
            }

            do {
                try process.run()
            } catch {
                clearHandlers(for: runningHelper)
                self.runningHelper = nil
                try? fileManager.removeItem(at: preparedRequest.runDirectory)
                continuation.resume(throwing: RunnerError.launchFailed(error.localizedDescription, localization))
                return
            }

            runningHelper.timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Timing.executionTimeout)
                } catch {
                    return
                }
                self?.timeOut(runID: runID)
            }
            logger.info("system soft restart helper launched")
        }
    }

    private func prepareRequest(for plan: SystemSoftRestartPlan) throws -> (runDirectory: URL, requestURL: URL) {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let runDirectory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: false)

        let requestURL = runDirectory.appendingPathComponent("request.json", isDirectory: false)
        let dockBackupURL = supportDirectory.appendingPathComponent("DockLayoutBackup.plist", isDirectory: false)
        let request = SystemSoftRestartRequest(
            hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            applicationPaths: plan.reopensApplications ? plan.applicationURLs.map(\.path) : [],
            reopensApplications: plan.reopensApplications,
            preservesDockLayout: plan.preservesDockLayout,
            dockBackupPath: plan.preservesDockLayout ? dockBackupURL.path : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: .atomic)
        return (runDirectory, requestURL)
    }

    private func deliver(events: [SystemSoftRestartEvent], runID: UUID) {
        guard let runningHelper, runningHelper.id == runID else { return }
        for event in events {
            runningHelper.onEvent(event)
        }
    }

    private func timeOut(runID: UUID) {
        guard let runningHelper, runningHelper.id == runID else { return }
        runningHelper.didTimeOut = true
        if runningHelper.process.isRunning {
            runningHelper.process.terminate()
        }
    }

    private func finish(
        runID: UUID,
        terminationStatus: Int32,
        snapshot: SystemSoftRestartOutputSnapshot
    ) {
        guard let runningHelper, runningHelper.id == runID else { return }

        self.runningHelper = nil
        runningHelper.timeoutTask?.cancel()
        clearHandlers(for: runningHelper)
        try? fileManager.removeItem(at: runningHelper.runDirectory)

        if runningHelper.didTimeOut {
            logger.error("system soft restart helper timed out")
            runningHelper.continuation.resume(throwing: RunnerError.timedOut(localization))
            return
        }

        guard terminationStatus == EXIT_SUCCESS else {
            let detail = snapshot.standardError.isEmpty
                ? localization.string("error.helperUnknown", defaultValue: "辅助进程意外退出。")
                : snapshot.standardError
            logger.error("system soft restart helper failed status=\(terminationStatus, privacy: .public)")
            runningHelper.continuation.resume(throwing: RunnerError.helperFailed(detail, localization))
            return
        }

        guard let completionEvent = snapshot.events.last(where: { $0.phase == .completed }) else {
            let detail = localization.string(
                "error.helperMissingCompletion",
                defaultValue: "辅助进程未返回完成状态。"
            )
            logger.error("system soft restart helper returned no completion event")
            runningHelper.continuation.resume(throwing: RunnerError.helperFailed(detail, localization))
            return
        }
        logger.info(
            "system soft restart helper completed warnings=\(completionEvent.warningCount, privacy: .public)"
        )
        runningHelper.continuation.resume(
            returning: SystemSoftRestartResult(
                warningCount: completionEvent.warningCount,
                diagnostics: completionEvent.diagnostics
            )
        )
    }

    private func clearHandlers(for runningHelper: RunningHelper) {
        runningHelper.standardOutput.fileHandleForReading.readabilityHandler = nil
        runningHelper.standardError.fileHandleForReading.readabilityHandler = nil
        runningHelper.process.terminationHandler = nil
    }
}
