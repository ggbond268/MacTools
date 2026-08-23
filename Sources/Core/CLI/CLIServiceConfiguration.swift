import Foundation

enum CLIServiceConfiguration {
    static let launchAgentPlistName = "app.ggbond.MacTools.cli-broker.plist"

#if DEBUG
    static let testServiceNameEnvironmentKey = "MACTOOLS_CLI_TEST_SERVICE_NAME"
    static let testDisableHostLaunchEnvironmentKey = "MACTOOLS_CLI_TEST_DISABLE_HOST_LAUNCH"
    static let testSignalReadyEnvironmentKey = "MACTOOLS_CLI_TEST_SIGNAL_READY"
#endif

    static func serviceName(bundleIdentifier: String?) -> String {
        "\(bundleIdentifier ?? "app.ggbond.MacTools.dev").cli-broker"
    }

    static func containingApplicationURL(
        executableURL: URL = resolvedExecutableURL()
    ) -> URL? {
        var candidate = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    static func containingApplicationBundle(
        executableURL: URL = resolvedExecutableURL()
    ) -> Bundle? {
        containingApplicationURL(executableURL: executableURL).flatMap(Bundle.init(url:))
    }

    static func resolvedExecutableURL(
        executablePath: String = CommandLine.arguments[0],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        guard !executablePath.contains("/") else {
            return URL(fileURLWithPath: executablePath)
        }
        for directory in (environment["PATH"] ?? "").split(
            separator: ":",
            omittingEmptySubsequences: false
        ) {
            let baseURL = directory.isEmpty
                ? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                : URL(fileURLWithPath: String(directory), isDirectory: true)
            let candidate = baseURL.appendingPathComponent(executablePath)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: executablePath)
    }

    static var runtimeServiceName: String {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment[testServiceNameEnvironmentKey],
           !override.isEmpty {
            return override
        }
#endif
        let identifier = containingApplicationBundle()?.bundleIdentifier
            ?? Bundle.main.bundleIdentifier
        return serviceName(bundleIdentifier: identifier)
    }
}
