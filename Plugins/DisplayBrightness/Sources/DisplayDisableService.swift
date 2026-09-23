import CoreGraphics
import Foundation
import AppKit
import IOKit

@_silgen_name("MTConfigureDisplayEnabled")
private func MTConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

@_silgen_name("MTDisplayEnableSPIAvailable")
private func MTDisplayEnableSPIAvailable() -> Bool

@MainActor
protocol DisplayDisableServicing: AnyObject {
    var isSupported: Bool { get }
    /// `nil` when the Mac has no lid or the state cannot be read.
    var isLidClosed: Bool? { get }

    func listDisplays() -> [DisplayDisableDisplay]
    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws
}

@MainActor
protocol DisplayDisableStateStoring: AnyObject {
    var records: [DisplayDisableRecord] { get set }
}

@MainActor
protocol DisplayLidObserving: AnyObject {
    func startObserving(onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

enum DisplayDisableServiceError: Error, LocalizedError {
    case privateSPIUnavailable
    case beginConfigurationFailed(CGError)
    case configureDisplayFailed(CGError)
    case completeConfigurationFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .privateSPIUnavailable:
            return DisplayBrightnessLocalization.string(
                "displayDisable.unsupported",
                defaultValue: "当前系统不支持关闭显示器"
            )
        case .beginConfigurationFailed:
            return DisplayBrightnessLocalization.string(
                "displayDisable.error.beginConfiguration",
                defaultValue: "无法开始显示器配置"
            )
        case .configureDisplayFailed:
            return DisplayBrightnessLocalization.string(
                "displayDisable.error.configureDisplay",
                defaultValue: "无法切换显示器状态"
            )
        case .completeConfigurationFailed:
            return DisplayBrightnessLocalization.string(
                "displayDisable.error.completeConfiguration",
                defaultValue: "无法提交显示器配置"
            )
        }
    }
}

@MainActor
final class SystemDisplayDisableService: DisplayDisableServicing {
    var isSupported: Bool {
        MTDisplayEnableSPIAvailable()
    }

    var isLidClosed: Bool? {
        Self.readLidClosed()
    }

    static func readLidClosed() -> Bool? {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            return nil
        }
        defer { IOObjectRelease(rootDomain) }

        return IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool
    }

    func listDisplays() -> [DisplayDisableDisplay] {
        let activeDisplayIDs = Set(Self.activeDisplayIDs())
        let visibleDisplayIDs = Set(Self.visibleAppKitDisplayIDs())

        return Self.onlineDisplayIDs().enumerated().map { index, displayID in
            let screen = NSScreen.screens.first(where: { screen in
                Self.displayID(for: screen) == displayID
            })
            let vendorNumber = CGDisplayVendorNumber(displayID)
            let modelNumber = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)

            return DisplayDisableDisplay(
                id: displayID,
                name: screen?.localizedName ?? "Display \(index + 1)",
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                isActive: activeDisplayIDs.contains(displayID),
                isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
                isVisibleToAppKit: visibleDisplayIDs.contains(displayID),
                isVirtual: Self.isVirtualDisplay(displayID),
                vendorNumber: vendorNumber == 0 ? nil : vendorNumber,
                modelNumber: modelNumber == 0 ? nil : modelNumber,
                serialNumber: serialNumber == 0 ? nil : serialNumber
            )
        }
    }

    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        guard isSupported else {
            throw DisplayDisableServiceError.privateSPIUnavailable
        }

        var config: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&config)
        guard beginError == .success, let config else {
            throw DisplayDisableServiceError.beginConfigurationFailed(beginError)
        }

        var committed = false
        defer {
            if !committed {
                CGCancelDisplayConfiguration(config)
            }
        }

        let configureError = MTConfigureDisplayEnabled(config, displayID, enabled)
        guard configureError == .success else {
            throw DisplayDisableServiceError.configureDisplayFailed(configureError)
        }

        // App-only: the window server reverts the change when this process exits, so a crash
        // or forced quit can never leave a display switched off with nothing left to restore it.
        let completeError = CGCompleteDisplayConfiguration(config, .forAppOnly)
        committed = completeError == .success
        guard completeError == .success else {
            throw DisplayDisableServiceError.completeConfigurationFailed(completeError)
        }
    }

    private static func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        let info = Arm64DDCServiceMatcher.displayInfoDictionary(for: displayID)
        return (info?["kCGDisplayIsVirtualDevice"] as? Bool) ?? false
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        CGGetOnlineDisplayList(count, &displayIDs, &count)
        return Array(displayIDs.prefix(Int(count)))
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        CGGetActiveDisplayList(count, &displayIDs, &count)
        return Array(displayIDs.prefix(Int(count)))
    }

    private static func visibleAppKitDisplayIDs() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap(displayID(for:))
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        )?.uint32Value
    }
}

/// Watches the IOPMrootDomain clamshell state so a built-in display whose restore was refused
/// while the lid was closed comes back as soon as the lid opens.
@MainActor
final class SystemDisplayLidObserver: DisplayLidObserving {
    /// Outlives no observer: the retained box is released in `stopObserving`, and the callback
    /// only reaches the observer through a weak reference.
    private final class CallbackBox {
        weak var observer: SystemDisplayLidObserver?

        init(observer: SystemDisplayLidObserver) {
            self.observer = observer
        }
    }

    private var notificationPort: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var callbackBox: Unmanaged<CallbackBox>?
    private var onChange: (@MainActor () -> Void)?
    private var lastLidClosed: Bool?

    func startObserving(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard notificationPort == nil else {
            return
        }

        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            DisplayBrightnessLog.plugin.error("could not find IOPMrootDomain to observe the lid")
            return
        }
        defer { IOObjectRelease(rootDomain) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            DisplayBrightnessLog.plugin.error("could not create a lid notification port")
            return
        }

        let box = Unmanaged.passRetained(CallbackBox(observer: self))
        let result = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { context, _, _, _ in
                guard let context else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
                // The port delivers on the main queue. Read the clamshell property outside
                // the IOKit callback before acting on it.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        box.observer?.handleRootDomainMessage()
                    }
                }
            },
            box.toOpaque(),
            &notification
        )
        guard result == KERN_SUCCESS else {
            box.release()
            IONotificationPortDestroy(port)
            DisplayBrightnessLog.plugin.error("could not observe the lid: \(result, privacy: .public)")
            return
        }

        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notificationPort = port
        callbackBox = box
        lastLidClosed = SystemDisplayDisableService.readLidClosed()
    }

    func stopObserving() {
        onChange = nil
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        callbackBox?.release()
        callbackBox = nil
        lastLidClosed = nil
    }

    private func handleRootDomainMessage() {
        // The root domain also reports sleep, wake and other power events; act only when the
        // lid actually changed.
        let lidClosed = SystemDisplayDisableService.readLidClosed()
        guard lidClosed != lastLidClosed else {
            return
        }
        lastLidClosed = lidClosed
        onChange?()
    }
}
