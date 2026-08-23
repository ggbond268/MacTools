import AppKit
import Darwin
import Foundation

private enum HelperFailure: LocalizedError {
    case invalidArguments
    case invalidRequest(String)
    case rootExecutionRefused
    case hostUnavailable
    case dockBackupFailed(String)
    case launchdUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Expected --request followed by a request file path."
        case let .invalidRequest(detail):
            return "Invalid restart request: \(detail)"
        case .rootExecutionRefused:
            return "Refusing to restart services from the root bootstrap namespace."
        case .hostUnavailable:
            return "The MacTools host process is no longer running."
        case let .dockBackupFailed(detail):
            return "Dock layout backup failed before services were restarted: \(detail)"
        case .launchdUnavailable:
            return "The user launchd namespace could not be queried."
        }
    }
}

private struct CommandResult {
    let exitStatus: Int32
    let standardError: String
}

private struct ValidatedApplications {
    let urls: [URL]
    let diagnostics: [SystemSoftRestartDiagnostic]
}

private final class LaunchdFailureCollector {
    private(set) var diagnostics: [SystemSoftRestartDiagnostic] = []

    func append(label: UnsafePointer<CChar>?, errorNumber: Int32) {
        let jobLabel = label.map(String.init(cString:)) ?? "Unknown launchd job"
        let message = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorNumber)
        ).localizedDescription
        diagnostics.append(SystemSoftRestartDiagnostic(
            kind: .launchdJob,
            subject: jobLabel,
            message: message
        ))
    }
}

private struct EventEmitter {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func emit(_ event: SystemSoftRestartEvent) {
        guard let data = try? encoder.encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

@main
private struct SystemSoftRestartHelperMain {
    private static let maximumRequestBytes = 1024 * 1024
    private static let maximumApplicationCount = 512
    private static let maximumReportedDiagnostics = 32

    @MainActor
    static func main() async {
        do {
            let requestURL = try parseRequestURL(arguments: CommandLine.arguments)
            let request = try loadRequest(from: requestURL)
            try validate(request: request)
            try await execute(request: request)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            writeError(message)
            exit(EXIT_FAILURE)
        }
    }

    private static func parseRequestURL(arguments: [String]) throws -> URL {
        guard arguments.count == 3, arguments[1] == "--request" else {
            throw HelperFailure.invalidArguments
        }
        return URL(fileURLWithPath: arguments[2]).standardizedFileURL
    }

    private static func loadRequest(from url: URL) throws -> SystemSoftRestartRequest {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumRequestBytes
        else {
            throw HelperFailure.invalidRequest("The request file is missing or too large.")
        }

        do {
            return try JSONDecoder().decode(SystemSoftRestartRequest.self, from: Data(contentsOf: url))
        } catch {
            throw HelperFailure.invalidRequest(error.localizedDescription)
        }
    }

    private static func validate(request: SystemSoftRestartRequest) throws {
        guard geteuid() != 0 else {
            throw HelperFailure.rootExecutionRefused
        }
        guard request.schemaVersion == SystemSoftRestartRequest.currentSchemaVersion else {
            throw HelperFailure.invalidRequest("Unsupported schema version.")
        }
        guard request.hostProcessIdentifier > 1,
              request.hostProcessIdentifier != getpid(),
              request.applicationPaths.count <= maximumApplicationCount
        else {
            throw HelperFailure.invalidRequest("Invalid process or application count.")
        }

        errno = 0
        let hostStatus = kill(request.hostProcessIdentifier, 0)
        guard hostStatus == 0 || errno == EPERM else {
            throw HelperFailure.hostUnavailable
        }

        if request.preservesDockLayout {
            guard let dockBackupPath = request.dockBackupPath,
                  dockBackupPath.hasPrefix("/"),
                  URL(fileURLWithPath: dockBackupPath).pathExtension.lowercased() == "plist"
            else {
                throw HelperFailure.invalidRequest("Dock backup path is invalid.")
            }
        }
    }

    @MainActor
    private static func execute(request: SystemSoftRestartRequest) async throws {
        let emitter = EventEmitter()
        let validatedApplications = validatedApplicationURLs(from: request.applicationPaths)
        let applicationURLs = validatedApplications.urls
        var diagnostics = validatedApplications.diagnostics
        var warningCount = diagnostics.count

        emitter.emit(SystemSoftRestartEvent(
            phase: .preparing,
            applicationCount: request.reopensApplications ? applicationURLs.count : 0,
            warningCount: warningCount
        ))

        if request.preservesDockLayout, let dockBackupPath = request.dockBackupPath {
            emitter.emit(SystemSoftRestartEvent(
                phase: .backingUpDock,
                applicationCount: applicationURLs.count,
                warningCount: warningCount
            ))
            try backupDockLayout(to: URL(fileURLWithPath: dockBackupPath))
        }

        emitter.emit(SystemSoftRestartEvent(
            phase: .restartingServices,
            applicationCount: applicationURLs.count,
            warningCount: warningCount
        ))
        var restartSummary = MTRestartSummary(attemptedCount: 0, stoppedCount: 0, failedCount: 0)
        let launchdFailureCollector = LaunchdFailureCollector()
        let restartError = MTRestartUserJobs(
            getpid(),
            request.hostProcessIdentifier,
            &restartSummary,
            { label, errorNumber, rawCollector in
                guard let rawCollector else { return }
                Unmanaged<LaunchdFailureCollector>
                    .fromOpaque(rawCollector)
                    .takeUnretainedValue()
                    .append(label: label, errorNumber: errorNumber)
            },
            Unmanaged.passUnretained(launchdFailureCollector).toOpaque()
        )
        guard restartError == 0 else {
            throw HelperFailure.launchdUnavailable
        }
        warningCount += Int(restartSummary.failedCount)
        diagnostics.append(contentsOf: launchdFailureCollector.diagnostics)

        emitter.emit(SystemSoftRestartEvent(
            phase: .waitingForServices,
            applicationCount: applicationURLs.count,
            warningCount: warningCount
        ))
        if !(await waitForEssentialUserServices()) {
            warningCount += 1
            diagnostics.append(SystemSoftRestartDiagnostic(
                kind: .essentialServices,
                subject: "Dock and SystemUIServer",
                message: "Still recovering when the readiness check ended."
            ))
        }

        if request.preservesDockLayout, let dockBackupPath = request.dockBackupPath {
            emitter.emit(SystemSoftRestartEvent(
                phase: .restoringDock,
                applicationCount: applicationURLs.count,
                warningCount: warningCount
            ))
            if let diagnostic = restoreDockLayout(from: URL(fileURLWithPath: dockBackupPath)) {
                warningCount += 1
                diagnostics.append(diagnostic)
            }
        }

        if request.reopensApplications {
            emitter.emit(SystemSoftRestartEvent(
                phase: .reopeningApplications,
                applicationCount: applicationURLs.count,
                warningCount: warningCount
            ))
            let reopenDiagnostics = await reopenApplications(at: applicationURLs)
            warningCount += reopenDiagnostics.count
            diagnostics.append(contentsOf: reopenDiagnostics)
        }

        let reportedDiagnostics = diagnosticsForReporting(
            diagnostics,
            totalWarningCount: warningCount
        )
        emitter.emit(SystemSoftRestartEvent(
            phase: .completed,
            applicationCount: applicationURLs.count,
            warningCount: warningCount,
            diagnostics: reportedDiagnostics
        ))
    }

    private static func validatedApplicationURLs(from paths: [String]) -> ValidatedApplications {
        var uniqueURLs: [String: URL] = [:]
        var diagnostics: [SystemSoftRestartDiagnostic] = []

        for path in paths {
            guard path.hasPrefix("/") else {
                diagnostics.append(invalidApplicationDiagnostic(path: path))
                continue
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath: url.path),
                  Bundle(url: url)?.bundleIdentifier != nil
            else {
                diagnostics.append(invalidApplicationDiagnostic(path: url.path))
                continue
            }
            uniqueURLs[url.path] = url
        }

        return ValidatedApplications(
            urls: uniqueURLs.values.sorted { $0.path < $1.path },
            diagnostics: diagnostics
        )
    }

    private static func invalidApplicationDiagnostic(path: String) -> SystemSoftRestartDiagnostic {
        let url = URL(fileURLWithPath: path)
        return SystemSoftRestartDiagnostic(
            kind: .applicationValidation,
            subject: url.deletingPathExtension().lastPathComponent.isEmpty
                ? "Application"
                : url.deletingPathExtension().lastPathComponent,
            message: "The saved application path is no longer valid: \(path)"
        )
    }

    private static func backupDockLayout(to backupURL: URL) throws {
        let parentDirectory = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }

        let result = runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/defaults"),
            arguments: ["export", "com.apple.dock", backupURL.path]
        )
        guard result.exitStatus == EXIT_SUCCESS,
              FileManager.default.fileExists(atPath: backupURL.path)
        else {
            throw HelperFailure.dockBackupFailed(
                result.standardError.isEmpty ? "defaults export failed." : result.standardError
            )
        }
    }

    @MainActor
    private static func waitForEssentialUserServices() async -> Bool {
        try? await Task.sleep(for: .seconds(2))

        for _ in 0..<24 {
            let runningBundleIdentifiers = Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            )
            if runningBundleIdentifiers.contains("com.apple.dock"),
               runningBundleIdentifiers.contains("com.apple.systemuiserver") {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    @MainActor
    private static func reopenApplications(
        at applicationURLs: [URL]
    ) async -> [SystemSoftRestartDiagnostic] {
        var diagnostics: [SystemSoftRestartDiagnostic] = []
        var runningPaths = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path }
        )

        for applicationURL in applicationURLs where !runningPaths.contains(applicationURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.hides = true

            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
                runningPaths.insert(applicationURL.path)
            } catch {
                diagnostics.append(SystemSoftRestartDiagnostic(
                    kind: .applicationReopen,
                    subject: applicationURL.deletingPathExtension().lastPathComponent,
                    message: error.localizedDescription
                ))
            }
        }

        return diagnostics
    }

    private static func restoreDockLayout(
        from backupURL: URL
    ) -> SystemSoftRestartDiagnostic? {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            return SystemSoftRestartDiagnostic(
                kind: .dockRestore,
                subject: "Dock",
                message: "The Dock layout backup could not be found."
            )
        }

        let importResult = runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/defaults"),
            arguments: ["import", "com.apple.dock", backupURL.path]
        )
        guard importResult.exitStatus == EXIT_SUCCESS else {
            return SystemSoftRestartDiagnostic(
                kind: .dockRestore,
                subject: "Dock",
                message: importResult.standardError.isEmpty
                    ? "The Dock layout could not be restored."
                    : importResult.standardError
            )
        }

        _ = runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/killall"),
            arguments: ["Dock"]
        )
        return nil
    }

    private static func diagnosticsForReporting(
        _ diagnostics: [SystemSoftRestartDiagnostic],
        totalWarningCount: Int
    ) -> [SystemSoftRestartDiagnostic] {
        guard diagnostics.count > maximumReportedDiagnostics else {
            return diagnostics
        }

        let visibleDiagnostics = Array(diagnostics.prefix(maximumReportedDiagnostics - 1))
        let omittedCount = max(0, totalWarningCount - visibleDiagnostics.count)
        return visibleDiagnostics + [SystemSoftRestartDiagnostic(
            kind: .summary,
            subject: "Additional issues",
            message: "\(omittedCount) additional issue(s) were omitted from this report."
        )]
    }

    private static func runCommand(executableURL: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CommandResult(exitStatus: process.terminationStatus, standardError: errorText)
        } catch {
            return CommandResult(exitStatus: EXIT_FAILURE, standardError: error.localizedDescription)
        }
    }

    private static func writeError(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
