import AppKit
import Foundation
import MacToolsPluginKit

protocol BrowserAppleScriptExecuting: Sendable {
    func execute(_ script: String) async throws -> String?
}

enum BrowserAppleScriptExecutionError: Error, Equatable, Sendable {
    case invalidScript
    case executionFailed
    case timeout
}

struct BrowserAppleScriptSelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .browserAppleScript
    private let executor: any BrowserAppleScriptExecuting
    private let timeout: TimeInterval
    private let localization: PluginLocalization

    init(
        executor: any BrowserAppleScriptExecuting = DefaultBrowserAppleScriptExecutor(),
        timeout: TimeInterval = 0.2,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.executor = executor
        self.timeout = timeout
        self.localization = localization
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        guard let bundleID = context.frontmostApplicationBundleID else {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingApplication", defaultValue: "未找到当前应用")
            )
        }

        guard AppCaptureCompatibility.supportsAppleScriptSelection(bundleID) else {
            return failure(
                context: context,
                reason: localization.string("capture.error.unsupportedBrowserAutomation", defaultValue: "当前浏览器不支持自动化取词")
            )
        }

        guard let script = script(bundleID: bundleID) else {
            return failure(
                context: context,
                reason: localization.string("capture.error.invalidAutomationScript", defaultValue: "自动化脚本无效")
            )
        }

        let selectedText: String?
        do {
            selectedText = try await executeWithTimeout(script)
        } catch BrowserAppleScriptExecutionError.timeout {
            return failure(
                context: context,
                reason: localization.string("capture.error.automationTimeout", defaultValue: "自动化取词超时")
            )
        } catch BrowserAppleScriptExecutionError.invalidScript {
            return failure(
                context: context,
                reason: localization.string("capture.error.invalidAutomationScript", defaultValue: "自动化脚本无效")
            )
        } catch {
            return failure(
                context: context,
                reason: localization.string("capture.error.automationFailed", defaultValue: "自动化取词失败")
            )
        }

        return SelectedTextCaptureResult(
            text: selectedText,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: bundleID,
            failureReason: selectedText == nil
                ? localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
                : nil
        )
    }

    private func executeWithTimeout(_ script: String) async throws -> String? {
        let executor = executor
        let timeoutNanoseconds = Self.timeoutNanoseconds(for: timeout)

        return try await withCheckedThrowingContinuation { continuation in
            let box = BrowserAppleScriptContinuationBox()
            let operation = Task {
                do {
                    let result = try await executor.execute(script)
                    box.resume(continuation, returning: result)
                } catch {
                    box.resume(continuation, throwing: error)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                operation.cancel()
                box.resume(continuation, throwing: BrowserAppleScriptExecutionError.timeout)
            }
        }
    }

    private static func timeoutNanoseconds(for timeout: TimeInterval) -> UInt64 {
        UInt64(max(timeout, 0) * 1_000_000_000)
    }

    private func script(bundleID: String) -> String? {
        if AppCaptureCompatibility.isSafari(bundleID) {
            return """
            tell application id "\(bundleID)"
                do JavaScript "window.getSelection().toString();" in current tab of front window
            end tell
            """
        }

        guard AppCaptureCompatibility.supportsAppleScriptSelection(bundleID) else {
            return nil
        }

        return """
        tell application id "\(bundleID)"
            tell active tab of front window
                execute javascript "window.getSelection().toString();"
            end tell
        end tell
        """
    }

    private func failure(context: SelectedTextCaptureContext, reason: String) -> SelectedTextCaptureResult {
        SelectedTextCaptureResult(
            text: nil,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: reason
        )
    }
}

private struct DefaultBrowserAppleScriptExecutor: BrowserAppleScriptExecuting {
    func execute(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(throwing: BrowserAppleScriptExecutionError.invalidScript)
                    return
                }

                var errorInfo: NSDictionary?
                let descriptor = appleScript.executeAndReturnError(&errorInfo)
                guard errorInfo == nil else {
                    continuation.resume(throwing: BrowserAppleScriptExecutionError.executionFailed)
                    return
                }

                continuation.resume(returning: descriptor.stringValue)
            }
        }
    }
}

private final class BrowserAppleScriptContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<String?, any Error>,
        returning value: String?
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }

    func resume(
        _ continuation: CheckedContinuation<String?, any Error>,
        throwing error: any Error
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else { return }
        didResume = true
        continuation.resume(throwing: error)
    }
}
