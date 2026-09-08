import Foundation
import MacToolsPluginKit

// MARK: - Charge Mode
//
// The user-facing mode. Once enabled, the plugin always sits in one of these
// three modes. Mode transitions are explicit (user action) except for the
// auto-fallback from `.charging` / `.discharging` back to `.holdAtLimit` when
// the battery reaches the configured limit.

enum BatteryChargeMode: String, Codable, Equatable {
    /// Charging is inhibited at the SMC level. This is the default whenever
    /// the plugin is enabled. Crucially: even if the battery is BELOW the
    /// limit, charging stays inhibited until the user explicitly resumes.
    case holdAtLimit
    /// User explicitly resumed charging. The plugin will auto-transition back
    /// to `.holdAtLimit` once the battery reaches the configured limit.
    case charging
    /// Force-discharge via an SMC adapter-isolation key. The plugin will auto-transition back to
    /// `.holdAtLimit` once the battery falls to (or below) the configured limit.
    case discharging
}

// MARK: - Limit Range

enum BatteryChargeLimits {
    static let minimumPercent = 20
    static let maximumPercent = 100
    static let defaultPercent = 80
    static let percentStep = 1
}

// MARK: - SMC Capabilities (reported by helper `probe`)

struct BatterySMCCapabilities: Equatable {
    var hasCHTE: Bool
    var hasCH0BC: Bool
    var hasBCLM: Bool
    var hasCH0I: Bool
    var hasCHIE: Bool = false
    var hasCH0J: Bool = false

    /// True when we have at least one writable charge-inhibit key family.
    var canInhibit: Bool { hasCHTE || hasCH0BC || hasBCLM }
    /// True when any supported adapter-isolation key is available on this hardware.
    var canForceDischarge: Bool { hasCHIE || hasCH0J || hasCH0I }
    /// True when the only inhibit path is Intel's BCLM (soft ceiling that
    /// auto-resumes once battery drops below limit). The plugin surfaces a
    /// caveat in the UI in this case.
    var isBCLMOnly: Bool { hasBCLM && !hasCHTE && !hasCH0BC }

    static let none = BatterySMCCapabilities(
        hasCHTE: false, hasCH0BC: false, hasBCLM: false, hasCH0I: false
    )
}

// MARK: - Battery Snapshot

enum BatteryPowerState: Equatable {
    /// No internal battery (e.g., Mac mini / Mac Studio). Plugin is hidden.
    case unavailable
    /// Battery is currently charging (kIOPSIsChargingKey == true).
    case charging
    /// Battery is full and AC-connected.
    case charged
    /// On adapter but not actively charging — either at limit or inhibited.
    case acPower
    /// Running on battery (no adapter).
    case unplugged
    /// Unknown/error.
    case unknown
}

struct BatterySnapshot: Equatable {
    var isAvailable: Bool
    /// Battery level as a percentage (0–100). nil when unavailable.
    var levelPercent: Int?
    var state: BatteryPowerState
    /// True when the AC adapter is connected (drawing external power).
    var isOnAdapter: Bool

    var hasBattery: Bool { isAvailable }

    static let empty = BatterySnapshot(
        isAvailable: false,
        levelPercent: nil,
        state: .unavailable,
        isOnAdapter: false
    )
}

// MARK: - Write Errors

enum BatteryChargeWriteError: Error, LocalizedError, Equatable {
    case helperNotFound
    case helperInstallFailed(BatteryChargeHelperInstallFailure)
    case helperVerificationFailed
    case noSupportedSMCKey
    case writeFailed(BatteryChargeWriteFailure)

    var errorDescription: String? {
        localizedDescription(localization: BatteryChargeLimitLocalization.fallback)
    }

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .helperNotFound:
            return localization.string(
                "error.helperNotFound",
                defaultValue: "未找到内置电池控制组件。请重新安装电池充电上限插件。"
            )
        case .helperInstallFailed(let failure):
            return localization.format(
                "error.helperInstallFailed",
                defaultValue: "安装电池控制组件失败：%@",
                failure.localizedDescription(localization: localization)
            )
        case .helperVerificationFailed:
            return localization.string(
                "error.helperVerificationFailed",
                defaultValue: "电池控制组件校验失败。请重新安装电池充电上限插件。"
            )
        case .noSupportedSMCKey:
            return localization.string(
                "error.noSupportedSMCKey",
                defaultValue: "当前 Mac 固件未提供可写的充电控制键。可能是 macOS 已升级到不支持的版本。"
            )
        case .writeFailed(let failure):
            return localization.format(
                "error.writeFailed",
                defaultValue: "写入充电控制失败：%@",
                failure.localizedDescription(localization: localization)
            )
        }
    }
}

enum BatteryChargeHelperInstallFailure: Equatable {
    case missingAfterInstall
    case authorizationScriptUnavailable
    case systemMessage(String)

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .missingAfterInstall:
            localization.string("error.helperInstall.missingAfterInstall", defaultValue: "安装后仍无法找到组件")
        case .authorizationScriptUnavailable:
            localization.string("error.helperInstall.authorizationScriptUnavailable", defaultValue: "无法创建授权脚本")
        case .systemMessage(let message):
            message
        }
    }
}

enum BatteryChargeWriteFailure: Equatable {
    case inhibitCharging
    case resumeCharging
    case toggleDischarge

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .inhibitCharging:
            localization.string("error.write.inhibitCharging", defaultValue: "无法停止充电")
        case .resumeCharging:
            localization.string("error.write.resumeCharging", defaultValue: "无法恢复充电")
        case .toggleDischarge:
            localization.string("error.write.toggleDischarge", defaultValue: "无法切换放电模式")
        }
    }
}

// MARK: - SMC Protocols (for dependency injection / tests)

protocol BatteryChargeLimitReading: AnyObject {
    @MainActor func readSnapshot() -> BatterySnapshot
}

protocol BatteryChargeLimitWriting: AnyObject {
    @MainActor var isHelperAvailable: Bool { get }
    @MainActor var isInstalledHelperAvailable: Bool { get }
    @MainActor func probeCapabilities() -> BatterySMCCapabilities
    @MainActor @discardableResult func inhibitCharging(limitPercent: Int) -> BatteryChargeWriteError?
    @MainActor @discardableResult func resumeCharging() -> BatteryChargeWriteError?
    @MainActor @discardableResult func setForceDischarge(_ on: Bool) -> BatteryChargeWriteError?
}
