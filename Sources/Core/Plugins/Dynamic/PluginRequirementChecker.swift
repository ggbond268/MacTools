import AppKit
import Foundation

/// Evaluate declared prerequisites without launching apps or requesting permissions.
@MainActor
struct PluginRequirementChecker {
    enum Failure: LocalizedError, Equatable {
        case macOS(String)
        case application(String)

        var errorDescription: String? {
            switch self {
            case let .macOS(version):
                AppL10n.pluginsFormat("plugin.requirement.macOS", defaultValue: "需要 macOS %@ 或更高版本。", version)
            case let .application(name):
                AppL10n.pluginsFormat("plugin.requirement.application", defaultValue: "未找到所需应用：%@。", name)
            }
        }
    }

    var macOSVersion: () -> String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    var applicationInstalled: (String) -> Bool = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func failure(for requirements: PluginProductMetadata.Requirements?) -> Failure? {
        guard let requirements else { return nil }
        if let minimum = requirements.minimumMacOSVersion,
           !PluginVersionComparator.isVersion(macOSVersion(), atLeast: minimum) {
            return .macOS(minimum)
        }
        for application in requirements.applications where !applicationInstalled(application.bundleID) {
            return .application(application.name)
        }
        // Permissions remain setup guidance; they must not prevent package installation.
        return nil
    }

    func validate(_ requirements: PluginProductMetadata.Requirements?) throws {
        if let failure = failure(for: requirements) { throw failure }
    }
}
