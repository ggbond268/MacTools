import Foundation

enum AppCaptureCompatibility {
    private static let appleScriptSelectionBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
    ]

    static func supportsAppleScriptSelection(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appleScriptSelectionBundleIDs.contains(bundleID)
    }

    static func isSafari(_ bundleID: String?) -> Bool {
        bundleID == "com.apple.Safari"
    }
}
