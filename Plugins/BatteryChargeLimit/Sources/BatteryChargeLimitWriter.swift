import Foundation

/// Writes battery charge-control SMC values via the bundled privileged helper.
/// Follows the same setuid-helper + AppleScript install pattern used by
/// `FanControlSMCWriter`, with helper-side handling of CHTE / CH0B+CH0C /
/// BCLM key probing and CH0I force-discharge.
@MainActor
final class BatteryChargeLimitWriter: BatteryChargeLimitWriting {
    private enum Helper {
        static let bundledName = "mactools-battery-smc-helper"
        static let bundledSubdirectory = "SMCHelper"
        static let installPath = "/Library/PrivilegedHelperTools/cc.ggbond.mactools.battery-charge-limit.smc-helper"
        static let installDirectory = "/Library/PrivilegedHelperTools"
    }

    private let fileManager: FileManager
    private let resourceBundle: Bundle
    let helperInstallPath: String

    private var resolvedHelperPath: String?
    private var cachedCapabilities: BatterySMCCapabilities?

    init(
        resourceBundle: Bundle = .main,
        fileManager: FileManager = .default,
        releaseChannel: String? = Bundle.main.object(forInfoDictionaryKey: "MTReleaseChannel") as? String
    ) {
        self.resourceBundle = resourceBundle
        self.fileManager = fileManager
        self.helperInstallPath = Helper.installPath + (releaseChannel == "nightly" ? ".nightly" : "")
    }

    // MARK: - Public API

    var isHelperAvailable: Bool { bundledHelperURL != nil }

    var isInstalledHelperAvailable: Bool {
        guard let bundledHelperURL else {
            return false
        }

        return installedHelperPath(matching: bundledHelperURL) != nil
    }

    func probeCapabilities() -> BatterySMCCapabilities {
        if let cached = cachedCapabilities { return cached }

        let resolvedPath: String
        switch helperPath() {
        case .success(let p): resolvedPath = p
        case .failure: return .none
        }

        let output = runHelperCapturingOutput(path: resolvedPath, args: ["probe"])
        guard let json = output, let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
        else {
            return .none
        }

        let caps = BatterySMCCapabilities(
            hasCHTE: dict["CHTE"] ?? false,
            hasCH0BC: dict["CH0B_CH0C"] ?? false,
            hasBCLM: dict["BCLM"] ?? false,
            hasCH0I: dict["CH0I"] ?? false
        )
        cachedCapabilities = caps
        return caps
    }

    @discardableResult
    func inhibitCharging(limitPercent: Int) -> BatteryChargeWriteError? {
        let path: String
        switch helperPath() {
        case .success(let p): path = p
        case .failure(let e): return e
        }
        let clamped = max(BatteryChargeLimits.minimumPercent, min(BatteryChargeLimits.maximumPercent, limitPercent))
        if !runHelper(path: path, args: ["inhibit", "\(clamped)"]) {
            return .writeFailed(.inhibitCharging)
        }
        return nil
    }

    @discardableResult
    func resumeCharging() -> BatteryChargeWriteError? {
        let path: String
        switch helperPath() {
        case .success(let p): path = p
        case .failure(let e): return e
        }
        if !runHelper(path: path, args: ["resume"]) {
            return .writeFailed(.resumeCharging)
        }
        return nil
    }

    @discardableResult
    func setForceDischarge(_ on: Bool) -> BatteryChargeWriteError? {
        let path: String
        switch helperPath() {
        case .success(let p): path = p
        case .failure(let e): return e
        }
        if !runHelper(path: path, args: ["discharge", on ? "on" : "off"]) {
            return .writeFailed(.toggleDischarge)
        }
        return nil
    }

    // MARK: - Helper install / verification

    private var bundledHelperURL: URL? {
        resourceBundle.url(
            forResource: Helper.bundledName,
            withExtension: nil,
            subdirectory: Helper.bundledSubdirectory
        )
    }

    private func helperPath() -> Result<String, BatteryChargeWriteError> {
        guard let bundledHelperURL else { return .failure(.helperNotFound) }
        guard verifyBundleContainingBundledHelper(bundledHelperURL) else {
            return .failure(.helperVerificationFailed)
        }
        if let installed = installedHelperPath(matching: bundledHelperURL) {
            return .success(installed)
        }
        if let err = installBundledHelper(from: bundledHelperURL) {
            return .failure(err)
        }
        guard let installed = installedHelperPath(matching: bundledHelperURL) else {
            return .failure(.helperInstallFailed(.missingAfterInstall))
        }
        return .success(installed)
    }

    private func installedHelperPath(matching bundledHelperURL: URL) -> String? {
        if let cached = resolvedHelperPath,
           isExecutable(at: cached),
           installedHelperMatchesBundled(installedPath: cached, bundledURL: bundledHelperURL) {
            return cached
        }
        guard isExecutable(at: helperInstallPath),
              installedHelperMatchesBundled(installedPath: helperInstallPath, bundledURL: bundledHelperURL)
        else {
            return nil
        }
        resolvedHelperPath = helperInstallPath
        return helperInstallPath
    }

    private func isExecutable(at path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    private func installedHelperMatchesBundled(installedPath: String, bundledURL: URL) -> Bool {
        guard let installedAttrs = try? fileManager.attributesOfItem(atPath: installedPath),
              let installedSize = installedAttrs[.size] as? NSNumber,
              let installedModifiedAt = installedAttrs[.modificationDate] as? Date,
              let bundledAttrs = try? fileManager.attributesOfItem(atPath: bundledURL.path),
              let bundledSize = bundledAttrs[.size] as? NSNumber,
              let bundledModifiedAt = bundledAttrs[.modificationDate] as? Date,
              let installedData = try? Data(contentsOf: URL(fileURLWithPath: installedPath)),
              let bundledData = try? Data(contentsOf: bundledURL)
        else {
            return false
        }
        guard installedSize == bundledSize else { return false }
        return installedModifiedAt.timeIntervalSince(bundledModifiedAt) >= -1
            && installedData == bundledData
    }

    private func verifyBundleContainingBundledHelper(_ helperURL: URL) -> Bool {
        var current = helperURL.deletingLastPathComponent()
        while current.path != "/" {
            if current.pathExtension == "bundle" {
                return verifyCodeSignature(at: current)
            }
            current.deleteLastPathComponent()
        }
        return false
    }

    private func verifyCodeSignature(at url: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--strict", "--deep", url.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            BatteryChargeLimitLog.writer.error("codesign verification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func installBundledHelper(from sourceURL: URL) -> BatteryChargeWriteError? {
        guard isExecutable(at: sourceURL.path) else { return .helperNotFound }

        let command = [
            "/bin/mkdir -p \(shellQuoted(Helper.installDirectory))",
            "/usr/bin/install -o root -g wheel -m 4755 \(shellQuoted(sourceURL.path)) \(shellQuoted(helperInstallPath))",
            "/usr/bin/touch -r \(shellQuoted(sourceURL.path)) \(shellQuoted(helperInstallPath))",
            "/bin/chmod 4755 \(shellQuoted(helperInstallPath))"
        ].joined(separator: " && ")

        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        var appleScriptError: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return .helperInstallFailed(.authorizationScriptUnavailable)
        }

        _ = scriptObject.executeAndReturnError(&appleScriptError)
        if let appleScriptError {
            let message = appleScriptError["NSAppleScriptErrorMessage"] as? String
                ?? appleScriptError.description
            BatteryChargeLimitLog.writer.error("Battery SMC helper install failed: \(message, privacy: .public)")
            return .helperInstallFailed(.systemMessage(message))
        }

        resolvedHelperPath = nil
        return nil
    }

    @discardableResult
    private func runHelper(path: String, args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = ["LANG": "C"]
        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return true }

            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            BatteryChargeLimitLog.writer.error(
                "battery-smc-helper failed with status \(task.terminationStatus): \(message ?? "unknown", privacy: .public)"
            )
        } catch {
            BatteryChargeLimitLog.writer.error("battery-smc-helper launch failed: \(error.localizedDescription, privacy: .public)")
        }

        return false
    }

    private func runHelperCapturingOutput(path: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = ["LANG": "C"]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            BatteryChargeLimitLog.writer.error("battery-smc-helper probe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
