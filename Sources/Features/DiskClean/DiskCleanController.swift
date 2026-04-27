import Combine
import Foundation

enum DiskCleanControllerPhase: Equatable, Sendable {
    case idle
    case scanning
    case scanned
    case cleaning
    case completed
}

struct DiskCleanControllerSnapshot: Equatable, Sendable {
    let phase: DiskCleanControllerPhase
    let selectedChoices: Set<DiskCleanChoice>
    let scanResult: DiskCleanScanResult?
    let executionResult: DiskCleanExecutionResult?
    let isResultStale: Bool
    let errorMessage: String?
    let scanLogEntries: [DiskCleanScanLogEntry]

    init(
        phase: DiskCleanControllerPhase,
        selectedChoices: Set<DiskCleanChoice>,
        scanResult: DiskCleanScanResult?,
        executionResult: DiskCleanExecutionResult?,
        isResultStale: Bool,
        errorMessage: String?,
        scanLogEntries: [DiskCleanScanLogEntry] = []
    ) {
        self.phase = phase
        self.selectedChoices = selectedChoices
        self.scanResult = scanResult
        self.executionResult = executionResult
        self.isResultStale = isResultStale
        self.errorMessage = errorMessage
        self.scanLogEntries = scanLogEntries
    }

    var subtitle: String {
        switch phase {
        case .idle:
            return "选择清理范围"
        case .scanning:
            return "正在扫描"
        case .scanned:
            if isResultStale {
                return "清理范围已变化"
            }
            return scanResult.map { "\($0.cleanableCandidates.count) 项可清理" } ?? "扫描完成"
        case .cleaning:
            return "正在清理"
        case .completed:
            return "清理完成"
        }
    }

    var isBusy: Bool {
        phase == .scanning || phase == .cleaning
    }

    var canScan: Bool {
        !isBusy && !selectedChoices.isEmpty
    }

    var canClean: Bool {
        phase == .scanned
            && !isResultStale
            && scanResult?.cleanableCandidates.isEmpty == false
    }

    static let initial = DiskCleanControllerSnapshot(
        phase: .idle,
        selectedChoices: Set(DiskCleanChoice.allCases),
        scanResult: nil,
        executionResult: nil,
        isResultStale: false,
        errorMessage: nil
    )
}

@MainActor
protocol DiskCleanControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var snapshot: DiskCleanControllerSnapshot { get }

    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool)
    func scan()
    func cleanSelected(candidateIDs: Set<DiskCleanCandidate.ID>)
    func cancelCurrentOperation()
}

@MainActor
final class DiskCleanController: ObservableObject, DiskCleanControlling {
    private static let scanLogFlushIntervalNanoseconds: UInt64 = 100_000_000

    var onStateChange: (() -> Void)?

    @Published private(set) var snapshot: DiskCleanControllerSnapshot {
        didSet {
            onStateChange?()
        }
    }

    private let scanner: DiskCleanScanning
    private let executor: DiskCleanExecuting

    private var currentTask: Task<Void, Never>?
    private var currentOperationID: UUID?
    private var scanLogFlushTask: Task<Void, Never>?
    private var nextLogEntryID = 1

    init(
        scanner: DiskCleanScanning = DiskCleanScanner(),
        executor: DiskCleanExecuting = DiskCleanExecutor(),
        initialSnapshot: DiskCleanControllerSnapshot = .initial
    ) {
        self.scanner = scanner
        self.executor = executor
        snapshot = initialSnapshot
    }

    deinit {
        currentTask?.cancel()
    }

    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool) {
        var nextChoices = snapshot.selectedChoices
        if isSelected {
            nextChoices.insert(choice)
        } else {
            nextChoices.remove(choice)
        }

        snapshot = DiskCleanControllerSnapshot(
            phase: snapshot.phase,
            selectedChoices: nextChoices,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: isStale(scanResult: snapshot.scanResult, selectedChoices: nextChoices),
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    func scan() {
        guard snapshot.canScan else { return }

        cancelTaskOnly()

        let selectedChoices = snapshot.selectedChoices
        let operationID = UUID()
        currentOperationID = operationID
        nextLogEntryID = 1
        let scanLogBuffer = DiskCleanScanLogBuffer()
        let initialLogEntries = [
            makeLogEntry(
                DiskCleanScanLogMessage(
                    text: "开始扫描：\(selectedChoiceTitleList(selectedChoices))",
                    tone: .info
                )
            )
        ]
        snapshot = DiskCleanControllerSnapshot(
            phase: .scanning,
            selectedChoices: selectedChoices,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            errorMessage: nil,
            scanLogEntries: initialLogEntries
        )
        startScanLogFlushLoop(operationID: operationID, buffer: scanLogBuffer)

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan(choices: selectedChoices) { message in
                    await scanLogBuffer.append(message)
                }
                guard isCurrentOperation(operationID) else { return }
                await flushScanLogEntriesIfCurrent(operationID, buffer: scanLogBuffer)
                snapshot = DiskCleanControllerSnapshot(
                    phase: .scanned,
                    selectedChoices: selectedChoices,
                    scanResult: result,
                    executionResult: nil,
                    isResultStale: false,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                await flushScanLogEntriesIfCurrent(operationID, buffer: scanLogBuffer)
                snapshot = DiskCleanControllerSnapshot(
                    phase: .idle,
                    selectedChoices: selectedChoices,
                    scanResult: nil,
                    executionResult: nil,
                    isResultStale: false,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch {
                guard isCurrentOperation(operationID) else { return }
                await flushScanLogEntriesIfCurrent(operationID, buffer: scanLogBuffer)
                snapshot = DiskCleanControllerSnapshot(
                    phase: .idle,
                    selectedChoices: selectedChoices,
                    scanResult: nil,
                    executionResult: nil,
                    isResultStale: false,
                    errorMessage: Self.userFacingMessage(for: error),
                    scanLogEntries: scanLogEntries(
                        adding: [
                            DiskCleanScanLogMessage(
                                text: "扫描失败：\(Self.userFacingMessage(for: error))",
                                tone: .error
                            )
                        ],
                        to: snapshot.scanLogEntries
                    )
                )
                finishOperation(operationID)
            }
        }
    }

    func cleanSelected(candidateIDs: Set<DiskCleanCandidate.ID>) {
        guard snapshot.canClean, let scanResult = snapshot.scanResult else { return }

        cancelTaskOnly()

        let selectedChoices = snapshot.selectedChoices
        let operationID = UUID()
        currentOperationID = operationID
        snapshot = DiskCleanControllerSnapshot(
            phase: .cleaning,
            selectedChoices: selectedChoices,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: false,
            errorMessage: nil,
            scanLogEntries: snapshot.scanLogEntries
        )

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let executionResult = try await executor.clean(
                    candidates: scanResult.candidates,
                    selectedCandidateIDs: candidateIDs
                )
                guard isCurrentOperation(operationID) else { return }
                snapshot = DiskCleanControllerSnapshot(
                    phase: .completed,
                    selectedChoices: selectedChoices,
                    scanResult: scanResult,
                    executionResult: executionResult,
                    isResultStale: false,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                snapshot = DiskCleanControllerSnapshot(
                    phase: .scanned,
                    selectedChoices: selectedChoices,
                    scanResult: scanResult,
                    executionResult: nil,
                    isResultStale: false,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch {
                guard isCurrentOperation(operationID) else { return }
                snapshot = DiskCleanControllerSnapshot(
                    phase: .scanned,
                    selectedChoices: selectedChoices,
                    scanResult: scanResult,
                    executionResult: nil,
                    isResultStale: false,
                    errorMessage: Self.userFacingMessage(for: error),
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            }
        }
    }

    func cancelCurrentOperation() {
        let phase = snapshot.phase
        let selectedChoices = snapshot.selectedChoices
        let scanResult = snapshot.scanResult
        let isResultStale = snapshot.isResultStale
        let scanLogEntries = snapshot.scanLogEntries

        cancelTaskOnly()

        switch phase {
        case .scanning:
            snapshot = DiskCleanControllerSnapshot(
                phase: .idle,
                selectedChoices: selectedChoices,
                scanResult: nil,
                executionResult: nil,
                isResultStale: false,
                errorMessage: nil,
                scanLogEntries: scanLogEntries + [
                    makeLogEntry(DiskCleanScanLogMessage(text: "扫描已停止", tone: .warning))
                ]
            )
        case .cleaning:
            snapshot = DiskCleanControllerSnapshot(
                phase: .scanned,
                selectedChoices: selectedChoices,
                scanResult: scanResult,
                executionResult: nil,
                isResultStale: isResultStale,
                errorMessage: nil,
                scanLogEntries: scanLogEntries
            )
        case .idle, .scanned, .completed:
            break
        }
    }

    private func cancelTaskOnly() {
        currentTask?.cancel()
        currentTask = nil
        currentOperationID = nil
        scanLogFlushTask?.cancel()
        scanLogFlushTask = nil
    }

    private func finishOperation(_ operationID: UUID) {
        guard isCurrentOperation(operationID) else { return }
        currentTask = nil
        currentOperationID = nil
        scanLogFlushTask?.cancel()
        scanLogFlushTask = nil
    }

    private func startScanLogFlushLoop(operationID: UUID, buffer: DiskCleanScanLogBuffer) {
        scanLogFlushTask?.cancel()
        scanLogFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.scanLogFlushIntervalNanoseconds)
                } catch {
                    break
                }
                await self?.flushScanLogEntriesIfCurrent(operationID, buffer: buffer)
            }
        }
    }

    private func flushScanLogEntriesIfCurrent(
        _ operationID: UUID,
        buffer: DiskCleanScanLogBuffer
    ) async {
        let messages = await buffer.drain()
        guard isCurrentOperation(operationID) else { return }
        appendScanLogs(messages)
    }

    private func appendScanLogs(_ messages: [DiskCleanScanLogMessage]) {
        guard !messages.isEmpty else { return }

        snapshot = DiskCleanControllerSnapshot(
            phase: snapshot.phase,
            selectedChoices: snapshot.selectedChoices,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: scanLogEntries(adding: messages, to: snapshot.scanLogEntries)
        )
    }

    private func scanLogEntries(
        adding messages: [DiskCleanScanLogMessage],
        to existingEntries: [DiskCleanScanLogEntry]
    ) -> [DiskCleanScanLogEntry] {
        var entries = existingEntries
        entries.reserveCapacity(min(existingEntries.count + messages.count, 500))
        for message in messages {
            entries.append(makeLogEntry(message))
        }
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
        return entries
    }

    private func makeLogEntry(_ message: DiskCleanScanLogMessage) -> DiskCleanScanLogEntry {
        defer { nextLogEntryID += 1 }
        return DiskCleanScanLogEntry(
            id: nextLogEntryID,
            text: message.text,
            tone: message.tone
        )
    }

    private func selectedChoiceTitleList(_ choices: Set<DiskCleanChoice>) -> String {
        DiskCleanChoice.allCases
            .filter { choices.contains($0) }
            .map(\.title)
            .joined(separator: "、")
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        currentOperationID == operationID
    }

    private func isStale(
        scanResult: DiskCleanScanResult?,
        selectedChoices: Set<DiskCleanChoice>
    ) -> Bool {
        guard let scanResult else { return false }
        return scanResult.choices != selectedChoices
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

private actor DiskCleanScanLogBuffer {
    private var messages: [DiskCleanScanLogMessage] = []

    func append(_ message: DiskCleanScanLogMessage) {
        messages.append(message)
    }

    func drain() -> [DiskCleanScanLogMessage] {
        defer { messages.removeAll(keepingCapacity: true) }
        return messages
    }
}
