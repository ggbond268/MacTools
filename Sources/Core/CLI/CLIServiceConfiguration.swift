import Foundation

enum CLIServiceConfiguration {
    static let launchAgentPlistName = "app.ggbond.MacTools.cli-broker.plist"

    static func serviceName(bundleIdentifier: String?) -> String {
        "\(bundleIdentifier ?? "app.ggbond.MacTools.dev").cli-broker"
    }

    static func containingApplicationURL(
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
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
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
    ) -> Bundle? {
        containingApplicationURL(executableURL: executableURL).flatMap(Bundle.init(url:))
    }

    static var runtimeServiceName: String {
        let identifier = containingApplicationBundle()?.bundleIdentifier
            ?? Bundle.main.bundleIdentifier
        return serviceName(bundleIdentifier: identifier)
    }
}
