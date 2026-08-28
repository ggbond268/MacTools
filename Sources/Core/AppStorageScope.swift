import Foundation

enum AppStorageScope {
    static var applicationSupportDirectoryName: String {
        applicationSupportDirectoryName(infoDictionary: Bundle.main.infoDictionary)
    }

    static func applicationSupportDirectoryName(infoDictionary: [String: Any]?) -> String {
        if let configuredName = infoDictionary?["MTApplicationSupportDirectoryName"] as? String,
           !configuredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !configuredName.contains("$(") {
            return configuredName
        }

        #if DEBUG
        return "MacTools Dev"
        #else
        return "MacTools"
        #endif
    }

    static func applicationSupportRoot(
        fileManager: FileManager = .default,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return baseURL.appendingPathComponent(
            applicationSupportDirectoryName(infoDictionary: infoDictionary),
            isDirectory: true
        )
    }
}
