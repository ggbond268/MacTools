import Darwin
import Foundation

enum CLIServiceConfiguration {
    static let launchAgentPlistName = "app.ggbond.MacTools.cli-broker.plist"

    static func serviceName(bundleIdentifier: String?) -> String {
        "\(hostBundleIdentifier(for: bundleIdentifier)).cli-broker"
    }

    static func hostBundleIdentifier(for bundleIdentifier: String?) -> String {
        let identifier = bundleIdentifier ?? "app.ggbond.MacTools.dev"
        if identifier.hasSuffix(".cli-broker") {
            return String(identifier.dropLast(".cli-broker".count))
        }
        if identifier.hasSuffix(".cli") {
            return String(identifier.dropLast(".cli".count))
        }
        return identifier
    }

    static func containingApplicationURL(
        executableURL: URL = currentExecutableURL()
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

    static func currentExecutableURL() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return resolvedExecutableURL()
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    static func executableInfoDictionary(
        executableURL: URL? = nil
    ) -> [String: Any] {
        let url = executableURL ?? currentExecutableURL()
        return CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any] ?? [:]
    }

    static var runtimeCLIServiceName: String {
        return serviceName(
            bundleIdentifier: executableInfoDictionary()["CFBundleIdentifier"] as? String
        )
    }

    static var runtimeBrokerServiceName: String {
        return serviceName(
            bundleIdentifier: executableInfoDictionary()["CFBundleIdentifier"] as? String
        )
    }
}
