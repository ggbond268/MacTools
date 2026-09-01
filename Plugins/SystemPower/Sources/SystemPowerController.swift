import CoreServices
import Foundation
import IOKit.pwr_mgt
import OSLog

enum SystemPowerOperation: String, CaseIterable, Sendable {
    case sleep
    case logOut = "log-out"
    case restart
    case shutDown = "shut-down"
}

enum SystemPowerOperationResult: Equatable, Sendable {
    case succeeded
    case failed
    case automationPermissionDenied
}

enum SystemPowerController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SystemPowerController"
    )

    static func perform(_ operation: SystemPowerOperation) async -> SystemPowerOperationResult {
        await Task.detached(priority: .userInitiated) {
            switch operation {
            case .sleep:
                return requestSystemSleep() ? .succeeded : .failed
            case .logOut, .restart, .shutDown:
                guard let eventID = loginWindowEventID(for: operation) else {
                    return .failed
                }
                return sendLoginWindowEvent(eventID)
            }
        }.value
    }

    static func loginWindowEventID(for operation: SystemPowerOperation) -> AEEventID? {
        switch operation {
        case .sleep:
            nil
        case .logOut:
            AEEventID(kAELogOut)
        case .restart:
            AEEventID(kAEShowRestartDialog)
        case .shutDown:
            AEEventID(kAEShowShutdownDialog)
        }
    }

    private static func requestSystemSleep() -> Bool {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != IO_OBJECT_NULL else {
            return false
        }
        defer { IOServiceClose(connection) }

        return IOPMSleepSystem(connection) == kIOReturnSuccess
    }

    private static func sendLoginWindowEvent(_ eventID: AEEventID) -> SystemPowerOperationResult {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        do {
            _ = try event.sendEvent(
                options: [.noReply, .alwaysInteract, .canSwitchLayer],
                timeout: 10
            )
            return .succeeded
        } catch {
            let nsError = error as NSError
            logger.error(
                "Loginwindow Apple event failed eventID=\(eventID, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            return nsError.code == Int(errAEEventNotPermitted)
                ? .automationPermissionDenied
                : .failed
        }
    }
}
