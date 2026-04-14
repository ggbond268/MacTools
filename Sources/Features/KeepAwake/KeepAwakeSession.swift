import AppKit
import Foundation
import IOKit.pwr_mgt
import OSLog

@MainActor
final class KeepAwakeSession {
    enum EndReason {
        case userRequested
        case completed
    }

    private enum SessionError: LocalizedError {
        case invalidEndDate
        case assertionCreationFailed(IOReturn)

        var errorDescription: String? {
            switch self {
            case .invalidEndDate:
                return "自定义时间必须晚于当前时间。"
            case let .assertionCreationFailed(result):
                return "无法启用阻止休眠，系统返回错误 \(result)。"
            }
        }
    }

    private let logger = AppLog.keepAwakeSession
    private let onEnd: (EndReason) -> Void

    private var assertionID = IOPMAssertionID(0)
    private var autoStopTask: Task<Void, Never>?
    private var isStopping = false
    private var isObservingTermination = false

    init(onEnd: @escaping (EndReason) -> Void) {
        self.onEnd = onEnd
    }

    deinit {
        autoStopTask?.cancel()

        if assertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(assertionID)
        }

        if isObservingTermination {
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.willTerminateNotification,
                object: NSApp
            )
        }
    }

    func start(until endDate: Date?) throws {
        if assertionID == IOPMAssertionID(0) {
            try createAssertionIfNeeded()
        }

        try scheduleAutoStop(until: endDate)
        installTerminationObserverIfNeeded()
    }

    func requestStop(reason: EndReason) {
        finish(reason: reason)
    }

    private func installTerminationObserverIfNeeded() {
        guard !isObservingTermination else {
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: NSApp
        )
        isObservingTermination = true
    }

    private func createAssertionIfNeeded() throws {
        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacTools Keep Awake" as CFString,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            logger.error("failed to create keep-awake assertion result=\(result, privacy: .public)")
            throw SessionError.assertionCreationFailed(result)
        }

        assertionID = newAssertionID
    }

    private func scheduleAutoStop(until endDate: Date?) throws {
        autoStopTask?.cancel()
        autoStopTask = nil

        guard let endDate else {
            return
        }

        let remainingDuration = endDate.timeIntervalSinceNow

        guard remainingDuration > 0 else {
            throw SessionError.invalidEndDate
        }

        autoStopTask = Task { [weak self] in
            let duration = UInt64(remainingDuration * 1_000_000_000)

            do {
                try await Task.sleep(nanoseconds: duration)
            } catch {
                return
            }

            self?.finish(reason: .completed)
        }
    }

    private func finish(reason: EndReason) {
        guard !isStopping else {
            return
        }

        isStopping = true
        invalidateTerminationObserver()

        autoStopTask?.cancel()
        autoStopTask = nil

        if assertionID != IOPMAssertionID(0) {
            let existingAssertionID = assertionID
            assertionID = IOPMAssertionID(0)

            let result = IOPMAssertionRelease(existingAssertionID)

            if result != kIOReturnSuccess {
                logger.error("failed to release keep-awake assertion result=\(result, privacy: .public)")
            }
        }

        onEnd(reason)
    }

    private func invalidateTerminationObserver() {
        guard isObservingTermination else {
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.willTerminateNotification,
            object: NSApp
        )
        isObservingTermination = false
    }

    @objc
    private func handleAppWillTerminate() {
        requestStop(reason: .userRequested)
    }
}
