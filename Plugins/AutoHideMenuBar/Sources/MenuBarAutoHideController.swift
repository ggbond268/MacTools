import AppKit
import Foundation
import MacToolsPluginKit

enum MenuBarAutoHideMode: String, CaseIterable, Equatable {
    case always
    case desktopOnly = "desktop-only"
    case fullScreenOnly = "full-screen-only"
    case never

    init(hideOnDesktop: Bool, visibleInFullScreen: Bool) {
        switch (hideOnDesktop, visibleInFullScreen) {
        case (true, false): self = .always
        case (true, true): self = .desktopOnly
        case (false, false): self = .fullScreenOnly
        case (false, true): self = .never
        }
    }

    var hidesOnDesktop: Bool { self == .always || self == .desktopOnly }
    var isVisibleInFullScreen: Bool { self == .desktopOnly || self == .never }
    var hidesAnywhere: Bool { self != .never }
}

@MainActor
protocol MenuBarAutoHideControlling {
    func read() throws -> MenuBarAutoHideMode
    func setMode(_ mode: MenuBarAutoHideMode) throws
}

enum MenuBarAutoHideError: LocalizedError {
    case updateFailed(restored: Bool)

    var errorDescription: String? {
        let localization = PluginLocalization(bundle: Bundle(for: AutoHideMenuBarPluginFactory.self))
        switch self {
        case .updateFailed(true):
            return localization.string(
                "error.modeVerificationRestored",
                defaultValue: "Could not verify the menu bar setting. The original mode was restored."
            )
        case .updateFailed(false):
            return localization.string(
                "error.modeVerificationUnrestored",
                defaultValue: "Could not verify the menu bar setting, and the original mode could not be fully restored."
            )
        }
    }
}

/// Applies the two preferences used by macOS to represent all four menu-bar
/// visibility policies, then verifies both values before reporting success.
@MainActor
final class MenuBarAutoHideController: MenuBarAutoHideControlling {
    struct Access {
        let readDesktopAutoHide: () -> Bool
        let readVisibleInFullScreen: () -> Bool
        let writeDesktopAutoHide: (Bool) throws -> Void
        let writeVisibleInFullScreen: (Bool) throws -> Void
    }

    private let access: Access

    init(access: Access) {
        self.access = access
    }

    convenience init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.init(access: .init(
            readDesktopAutoHide: Self.readDesktopAutoHide,
            readVisibleInFullScreen: Self.readVisibleInFullScreen,
            writeDesktopAutoHide: { try Self.writeDesktopAutoHide($0, localization: localization) },
            writeVisibleInFullScreen: { try Self.writeVisibleInFullScreen($0, localization: localization) }
        ))
    }

    func read() throws -> MenuBarAutoHideMode {
        MenuBarAutoHideMode(
            hideOnDesktop: access.readDesktopAutoHide(),
            visibleInFullScreen: access.readVisibleInFullScreen()
        )
    }

    func setMode(_ mode: MenuBarAutoHideMode) throws {
        let previous = try read()
        guard previous != mode else { return }

        do {
            try write(mode)
            guard try read() == mode else { throw MenuBarAutoHideError.updateFailed(restored: false) }
        } catch {
            let restored: Bool
            do {
                try write(previous)
                restored = try read() == previous
            } catch {
                restored = false
            }
            throw MenuBarAutoHideError.updateFailed(restored: restored)
        }
    }

    private func write(_ mode: MenuBarAutoHideMode) throws {
        // Write full-screen visibility first. If Automation is denied while
        // updating the desktop policy, setMode restores this value.
        try access.writeVisibleInFullScreen(mode.isVisibleInFullScreen)
        try access.writeDesktopAutoHide(mode.hidesOnDesktop)
    }

    nonisolated static func resolvedMode(desktopAutoHide: Any?, visibleInFullScreen: Any?) -> MenuBarAutoHideMode {
        MenuBarAutoHideMode(
            hideOnDesktop: boolValue(from: desktopAutoHide) ?? false,
            visibleInFullScreen: boolValue(from: visibleInFullScreen) ?? false
        )
    }

    private nonisolated static func readDesktopAutoHide() -> Bool {
        let global = CFPreferencesCopyValue(
            "_HIHideMenuBar" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        if let value = boolValue(from: global) { return value }
        let legacy = CFPreferencesCopyAppValue("autohide-menubar" as CFString, "com.apple.dock" as CFString)
        return boolValue(from: legacy) ?? false
    }

    private nonisolated static func readVisibleInFullScreen() -> Bool {
        let value = CFPreferencesCopyValue(
            "AppleMenuBarVisibleInFullscreen" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return boolValue(from: value) ?? false
    }

    private nonisolated static func boolValue(from value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        default: nil
        }
    }

    private static func writeDesktopAutoHide(_ enabled: Bool, localization: PluginLocalization) throws {
        let script = """
        tell application "System Events"
            tell dock preferences
                set autohide menu bar to \(enabled ? "true" : "false")
            end tell
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            throw NSError(
                domain: "AutoHideMenuBarPlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: localization.string(
                    "error.toggleFailed",
                    defaultValue: "Could not update menu bar visibility."
                )]
            )
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            throw NSError(
                domain: "AutoHideMenuBarPlugin",
                code: (error[NSAppleScript.errorNumber] as? Int) ?? 1,
                userInfo: [NSLocalizedDescriptionKey: (error[NSAppleScript.errorMessage] as? String)
                    ?? localization.string("error.toggleFailed", defaultValue: "Could not update menu bar visibility.")]
            )
        }
        DistributedNotificationCenter.default().postNotificationName(
            .init("AppleInterfaceMenuBarHidingChangedNotification"),
            object: nil,
            deliverImmediately: true
        )
    }

    private static func writeVisibleInFullScreen(_ visible: Bool, localization: PluginLocalization) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = [
            "write", "NSGlobalDomain", "AppleMenuBarVisibleInFullscreen",
            "-bool", visible ? "true" : "false",
        ]
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw NSError(
                domain: "AutoHideMenuBarPlugin",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: localization.string(
                    "error.toggleFailed",
                    defaultValue: "Could not update menu bar visibility."
                )]
            )
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AutoHideMenuBarPlugin",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false
                    ? message!
                    : localization.string("error.toggleFailed", defaultValue: "Could not update menu bar visibility.")]
            )
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            .init("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification"),
            object: nil,
            deliverImmediately: true
        )
    }
}
