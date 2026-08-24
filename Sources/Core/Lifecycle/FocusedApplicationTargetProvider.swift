import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
protocol FocusedApplicationTargetProviding: AnyObject {
    var currentHostWindowProvider: (() -> NSWindow?)? { get set }
    func captureCurrentTarget()
    func target() -> PluginFocusedWindowTarget?
}

@MainActor
protocol FocusedApplicationTargetApplication: AnyObject {
    var processIdentifier: Int32 { get }
    var isTerminated: Bool { get }
}

extension NSRunningApplication: FocusedApplicationTargetApplication {}

/// Retains the most recently eligible application and, for MacTools, the exact Settings window so
/// transient action surfaces still operate on the window the user was working with.
@MainActor
final class SystemFocusedApplicationTargetProvider: NSObject, FocusedApplicationTargetProviding {
    private let currentProcessIdentifier: Int32
    private let frontmostApplication: () -> (any FocusedApplicationTargetApplication)?
    private var lastTargetApplication: (any FocusedApplicationTargetApplication)?
    private var lastTargetWindowNumber: Int?
    var currentHostWindowProvider: (() -> NSWindow?)?

    init(
        workspace: NSWorkspace = .shared,
        currentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        observesWorkspace: Bool = true,
        frontmostApplication: (() -> (any FocusedApplicationTargetApplication)?)? = nil
    ) {
        self.currentProcessIdentifier = currentProcessIdentifier
        self.frontmostApplication = frontmostApplication ?? {
            workspace.frontmostApplication
        }
        super.init()

        recordActivatedApplication(self.frontmostApplication())
        if observesWorkspace {
            workspace.notificationCenter.addObserver(
                self,
                selector: #selector(applicationDidActivate(_:)),
                name: NSWorkspace.didActivateApplicationNotification,
                object: workspace
            )
        }
    }

    func captureCurrentTarget() {
        _ = targetInstance()
    }

    func target() -> PluginFocusedWindowTarget? {
        guard let target = targetInstance(),
              let application = target.application as? NSRunningApplication
        else {
            return nil
        }
        if application.processIdentifier == currentProcessIdentifier {
            guard let windowNumber = target.windowNumber,
                  NSApp.windows.contains(where: {
                      $0.windowNumber == windowNumber && $0.isVisible
                  })
            else {
                clearLastTarget()
                return nil
            }
        }
        return PluginFocusedWindowTarget(
            application: application,
            preferredWindowNumber: target.windowNumber
        )
    }

    func targetProcessIdentifier() -> Int32? {
        targetInstance()?.application.processIdentifier
    }

    func targetWindowNumber() -> Int? {
        targetInstance()?.windowNumber
    }

    private func targetInstance() -> TargetInstance? {
        let currentFrontmostApplication = frontmostApplication()
        if let frontmostApplication = currentFrontmostApplication,
           isExternal(frontmostApplication) {
            recordTarget(application: frontmostApplication, windowNumber: nil)
            return TargetInstance(application: frontmostApplication, windowNumber: nil)
        }
        if let frontmostApplication = currentFrontmostApplication,
           frontmostApplication.processIdentifier == currentProcessIdentifier,
           let window = currentHostWindowProvider?(),
           window.isVisible {
            recordTarget(application: frontmostApplication, windowNumber: window.windowNumber)
            return TargetInstance(
                application: frontmostApplication,
                windowNumber: window.windowNumber
            )
        }
        guard let lastTargetApplication,
              !lastTargetApplication.isTerminated
        else {
            clearLastTarget()
            return nil
        }
        return TargetInstance(
            application: lastTargetApplication,
            windowNumber: lastTargetWindowNumber
        )
    }

    func recordActivatedApplication(
        _ application: (any FocusedApplicationTargetApplication)?
    ) {
        guard let application, isExternal(application) else { return }
        recordTarget(application: application, windowNumber: nil)
    }

    func recordHostTarget(
        application: any FocusedApplicationTargetApplication,
        windowNumber: Int
    ) {
        guard application.processIdentifier == currentProcessIdentifier,
              windowNumber > 0,
              !application.isTerminated
        else { return }
        recordTarget(application: application, windowNumber: windowNumber)
    }

    @objc
    private func applicationDidActivate(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        recordActivatedApplication(application)
    }

    private func isExternal(_ application: any FocusedApplicationTargetApplication) -> Bool {
        application.processIdentifier > 0
            && application.processIdentifier != currentProcessIdentifier
            && !application.isTerminated
    }

    private func recordTarget(
        application: any FocusedApplicationTargetApplication,
        windowNumber: Int?
    ) {
        lastTargetApplication = application
        lastTargetWindowNumber = windowNumber
    }

    private func clearLastTarget() {
        lastTargetApplication = nil
        lastTargetWindowNumber = nil
    }

    private struct TargetInstance {
        let application: any FocusedApplicationTargetApplication
        let windowNumber: Int?
    }
}
