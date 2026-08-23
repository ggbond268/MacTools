import AppKit
import Foundation

struct SystemSoftRestartApplicationScanner {
    private static let systemManagedBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
    ]

    private let applicationDirectories: [URL]
    private let accessoryApplicationDirectories: [URL]

    init() {
        let userApplicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        self.applicationDirectories = userApplicationDirectories + [
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
        self.accessoryApplicationDirectories = userApplicationDirectories
    }

    init(
        applicationDirectories: [URL],
        accessoryApplicationDirectories: [URL]? = nil
    ) {
        self.applicationDirectories = applicationDirectories
        self.accessoryApplicationDirectories = accessoryApplicationDirectories
            ?? applicationDirectories
    }

    func runningApplicationURLs(excludingProcessIdentifier excludedPID: pid_t) -> [URL] {
        var uniqueURLs: [String: URL] = [:]

        for application in NSWorkspace.shared.runningApplications {
            guard application.processIdentifier != excludedPID,
                  !application.isTerminated,
                  let bundleURL = application.bundleURL,
                  bundleURL.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath: bundleURL.path),
                  isEligibleForManualReopen(
                      activationPolicy: application.activationPolicy,
                      bundleURL: bundleURL
                  )
            else {
                continue
            }

            if let bundleIdentifier = application.bundleIdentifier,
               Self.systemManagedBundleIdentifiers.contains(bundleIdentifier) {
                continue
            }

            uniqueURLs[bundleURL.standardizedFileURL.path] = bundleURL.standardizedFileURL
        }

        return uniqueURLs.values.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func isEligibleForManualReopen(
        activationPolicy: NSApplication.ActivationPolicy,
        bundleURL: URL
    ) -> Bool {
        let standardizedURL = bundleURL.standardizedFileURL
        guard activationPolicy == .regular || activationPolicy == .accessory,
              isInside(standardizedURL, directories: applicationDirectories),
              !isNestedApplicationBundle(standardizedURL),
              let bundle = Bundle(url: standardizedURL),
              bundle.bundleIdentifier != nil,
              !bundleFlag(named: "LSBackgroundOnly", in: bundle)
        else {
            return false
        }

        if activationPolicy == .accessory,
           !isInside(standardizedURL, directories: accessoryApplicationDirectories) {
            return false
        }
        return true
    }

    private func isInside(_ url: URL, directories: [URL]) -> Bool {
        directories.contains { directory in
            let rootPath = directory.standardizedFileURL.path
            return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
        }
    }

    private func isNestedApplicationBundle(_ url: URL) -> Bool {
        url.deletingLastPathComponent().pathComponents.contains {
            $0.lowercased().hasSuffix(".app")
        }
    }

    private func bundleFlag(named key: String, in bundle: Bundle) -> Bool {
        if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return value.boolValue
        }
        return false
    }
}
