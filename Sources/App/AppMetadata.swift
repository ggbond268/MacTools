import AppKit
import Foundation

enum AppMetadata {
    static let repositoryDisplayName = "ggbond268/MacTools"

    static var appName: String {
        bundleString("CFBundleDisplayName")
            ?? bundleString(kCFBundleNameKey as String)
            ?? "MacTools"
    }

    static var versionDescription: String {
        let shortVersion = bundleString("CFBundleShortVersionString") ?? "0.2.0"
        let buildNumber = bundleString(kCFBundleVersionKey as String) ?? "2"
        return "\(shortVersion) (\(buildNumber))"
    }

    static var repositoryURL: URL {
        URL(string: "https://github.com/ggbond268/MacTools")!
    }

    static var aboutDescription: String {
        "一款免费、开源的 macOS 菜单栏工具集合。\n使用 SwiftUI 构建。"
    }

    static var authorDescription: String {
        "项目地址"
    }

    static var appIcon: NSImage? {
        guard let iconName = bundleString("CFBundleIconName") ?? bundleString("CFBundleIconFile") else {
            return nil
        }

        let imageName = NSImage.Name(iconName)
        return NSImage(named: imageName) ?? Bundle.main.image(forResource: imageName)
    }

    private static func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
