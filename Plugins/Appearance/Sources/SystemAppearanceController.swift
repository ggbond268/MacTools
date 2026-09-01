import AppKit
import Darwin
import Foundation
import MacToolsPluginKit

enum SystemAppearanceMode: String, CaseIterable {
    case auto
    case light
    case dark

    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct SystemAppearanceSnapshot: Equatable {
    let mode: SystemAppearanceMode
    let isDark: Bool
}

@MainActor
protocol SystemAppearanceControlling {
    func read() throws -> SystemAppearanceSnapshot
    func setMode(_ mode: SystemAppearanceMode) throws
}

enum SystemAppearanceError: LocalizedError {
    case unavailable
    case verificationFailed(restored: Bool)

    var errorDescription: String? {
        let localization = PluginLocalization(bundle: Bundle(for: AppearancePluginFactory.self))
        switch self {
        case .unavailable:
            return localization.string("error.modeUnavailable", defaultValue: "This macOS version cannot set automatic appearance directly.")
        case let .verificationFailed(restored):
            return restored
                ? localization.string("error.modeVerificationRestored", defaultValue: "Appearance verification failed. The original mode was restored.")
                : localization.string("error.modeVerificationUnrestored", defaultValue: "Appearance verification failed. The original mode could not be fully restored.")
        }
    }
}

/// Uses the same guarded mode-switching entry points as macOS Appearance settings.
/// Automatic mode is a policy, separate from the currently rendered light/dark theme.
@MainActor
final class SystemAppearanceController: SystemAppearanceControlling {
    struct Access {
        let readDark: () -> Bool
        let readAutomatic: () -> Bool
        let writeDark: (Bool) -> Void
        let writeAutomatic: (Bool) -> Void
        let persistedModeMatches: (SystemAppearanceMode) -> Bool
    }

    private let access: Access?

    init(access: Access?) { self.access = access }

    convenience init() {
        if let runtime = Self.runtime {
            self.init(access: .init(readDark: { runtime.readDark() }, readAutomatic: { runtime.readAutomatic() },
                                   writeDark: { runtime.writeDark($0) }, writeAutomatic: { runtime.writeAutomatic($0) },
                                   persistedModeMatches: Self.persistedModeMatches))
        } else {
            self.init(access: nil)
        }
    }

    private typealias ReadFlag = @convention(c) () -> Bool
    private typealias WriteFlag = @convention(c) (Bool) -> Void

    private struct Runtime {
        let library: UnsafeMutableRawPointer
        let readDark: ReadFlag
        let readAutomatic: ReadFlag
        let writeDark: WriteFlag
        let writeAutomatic: WriteFlag
    }

    private static let runtime: Runtime? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let readDark = dlsym(library, "SLSGetAppearanceThemeLegacy"),
              let readAutomatic = dlsym(library, "SLSGetAppearanceThemeSwitchesAutomatically"),
              let writeDark = dlsym(library, "SLSSetAppearanceThemeLegacy"),
              let writeAutomatic = dlsym(library, "SLSSetAppearanceThemeSwitchesAutomatically") else {
            dlclose(library)
            return nil
        }
        return Runtime(library: library,
                       readDark: unsafeBitCast(readDark, to: ReadFlag.self),
                       readAutomatic: unsafeBitCast(readAutomatic, to: ReadFlag.self),
                       writeDark: unsafeBitCast(writeDark, to: WriteFlag.self),
                       writeAutomatic: unsafeBitCast(writeAutomatic, to: WriteFlag.self))
    }()

    func read() throws -> SystemAppearanceSnapshot {
        guard let access else { throw SystemAppearanceError.unavailable }
        let dark = access.readDark()
        return .init(mode: access.readAutomatic() ? .auto : (dark ? .dark : .light), isDark: dark)
    }

    func setMode(_ mode: SystemAppearanceMode) throws {
        guard let access else { throw SystemAppearanceError.unavailable }
        let previous = try read()
        if previous.mode == mode, access.persistedModeMatches(mode) { return }
        write(mode, access: access)
        guard try read().mode == mode, access.persistedModeMatches(mode) else {
            write(previous.mode, access: access)
            let restored = (try? read().mode) == previous.mode && access.persistedModeMatches(previous.mode)
            throw SystemAppearanceError.verificationFailed(restored: restored)
        }
    }

    private func write(_ mode: SystemAppearanceMode, access: Access) {
        access.writeAutomatic(mode == .auto)
        if mode != .auto { access.writeDark(mode == .dark) }
        // The runtime owns scheduling and broadcasts; do not emulate Auto with a timer.
    }

    private static func persistedModeMatches(_ mode: SystemAppearanceMode) -> Bool {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let automatic = (CFPreferencesCopyValue("AppleInterfaceStyleSwitchesAutomatically" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.boolValue ?? false
        guard automatic == (mode == .auto) else { return false }
        if mode == .auto { return true }
        let style = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return (style == "Dark") == (mode == .dark)
    }
}
