import Foundation

enum AppCaptureCompatibility {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
    ]

    private static let appleScriptSelectionBundleIDs = browserBundleIDs

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    static func supportsAppleScriptSelection(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appleScriptSelectionBundleIDs.contains(bundleID)
    }

    static func isSafari(_ bundleID: String?) -> Bool {
        bundleID == "com.apple.Safari"
    }
}
