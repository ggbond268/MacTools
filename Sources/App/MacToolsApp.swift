import AppKit
import AppIntents
import MacToolsAppIntents
import SwiftUI
@preconcurrency import UserNotifications

@main
struct MacToolsApp: App, AppIntentsPackage {
    @NSApplicationDelegateAdaptor(MacToolsAppDelegate.self) private var appDelegate

    nonisolated static var includedPackages: [any AppIntentsPackage.Type] {
        [MacToolsAppIntentsPackage.self]
    }

    init() {
        AppLanguagePreference.applyStoredPreference()
        MacToolsAppShortcuts.refreshParameters()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Settings is presented exclusively by AppWindowRouter. Remove the
            // placeholder scene's command so it can never expose an empty window.
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

@MainActor
final class MacToolsAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let maximumPendingURLCount = 32

    private let instanceCoordinator: AppInstanceCoordinator
    private let acceptedURLSchemes: Set<String>
    private var launchDisposition: AppInstanceLaunchDisposition?
    private var didFinishLaunching = false
    private var runtime: MacToolsAppRuntime?
    private var instanceCoordinationTask: Task<Void, Never>?
    private var pendingURLs = [URL]()
    #if DEBUG
    private var showSettingsForTesting: (() -> Void)?
    #endif

    override convenience init() {
        self.init(acceptedURLSchemes: RightClickURLRouter.bundleURLSchemes())
    }

    init(acceptedURLSchemes: Set<String>) {
        instanceCoordinator = AppInstanceCoordinator()
        self.acceptedURLSchemes = Set(acceptedURLSchemes.map { $0.lowercased() })
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else {
            launchDisposition = .primary(recoveryRequested: false)
            return
        }

        launchDisposition = .secondary(.timedOut)
        let commandHandler = instanceCommandHandler()
        instanceCoordinationTask = Task { [weak self, instanceCoordinator, commandHandler] in
            let forwardingDeadline = AppInstanceCoordinator.makeForwardingDeadline()
            let settingsRecoveryDeadline = AppInstanceCoordinator.makeSettingsRecoveryDeadline(
                forwardingDeadline: forwardingDeadline
            )
            await instanceCoordinator.setCommandHandler(commandHandler)
            let disposition: AppInstanceLaunchDisposition
            if await instanceCoordinator.claimPrimaryPortIfPossible() {
                disposition = .primary(recoveryRequested: false)
            } else {
                disposition = await instanceCoordinator.resolveSecondaryLaunch(
                    requestSettings: false,
                    deadline: settingsRecoveryDeadline
                )
            }
            guard !Task.isCancelled else { return }
            await self?.completeLaunch(disposition, forwardingDeadline: forwardingDeadline)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        guard case let .primary(recoveryRequested) = launchDisposition else { return }
        startRuntime(recoveryRequested: recoveryRequested)
    }

    private func startRuntime(recoveryRequested: Bool) {
        guard runtime == nil else { return }
        let runtime = MacToolsAppRuntime()
        self.runtime = runtime
        runtime.start(notificationDelegate: self)
        let urls = pendingURLs
        pendingURLs.removeAll()
        runtime.handle(urls: urls)
        if recoveryRequested {
            _ = requestSettingsRecovery()
        }
    }

    private func completeLaunch(
        _ disposition: AppInstanceLaunchDisposition,
        forwardingDeadline: Date
    ) async {
        switch disposition {
        case let .primary(recoveryRequested):
            launchDisposition = disposition
            if didFinishLaunching {
                startRuntime(recoveryRequested: recoveryRequested)
            }
        case let .secondary(result):
            var urlForwardingResult = AppInstanceForwardingOutcome.acknowledged
            while !pendingURLs.isEmpty && urlForwardingResult == .acknowledged {
                let urls = pendingURLs
                pendingURLs.removeAll()
                urlForwardingResult = await instanceCoordinator.forwardURLs(
                    urls,
                    deadline: forwardingDeadline
                )
                if urlForwardingResult == .becamePrimary {
                    pendingURLs.insert(contentsOf: urls, at: 0)
                    launchDisposition = .primary(recoveryRequested: false)
                    startRuntime(recoveryRequested: false)
                    return
                }
            }

            AppLog.instanceCoordination.notice(
                "Secondary instance terminating: \(String(describing: result), privacy: .public), deep links: \(String(describing: urlForwardingResult), privacy: .public)"
            )
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let runtime else {
            _ = enqueuePendingURLs(urls)
            return
        }
        runtime.handle(urls: urls)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        _ = requestSettingsRecovery()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceCoordinationTask?.cancel()
        instanceCoordinationTask = nil
        runtime?.terminate()
        Task { [instanceCoordinator] in
            await instanceCoordinator.invalidate()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func requestSettingsRecovery() -> AppInstanceResponse {
        #if DEBUG
        if let showSettingsForTesting {
            showSettingsForTesting()
            return .accepted
        }
        #endif

        return runtime?.showSettings() == true ? .accepted : .notReady
    }

    private func instanceCommandHandler() -> @Sendable (AppInstanceCommand) -> AppInstanceResponse {
        { [weak self] command in
            MainActor.assumeIsolated {
                self?.handleInstanceCommand(command) ?? .notReady
            }
        }
    }

    private func handleInstanceCommand(_ command: AppInstanceCommand) -> AppInstanceResponse {
        switch command.command {
        case AppInstanceCommand.probe:
            return .accepted
        case AppInstanceCommand.showSettings:
            return requestSettingsRecovery()
        case AppInstanceCommand.openURLs:
            let urls = command.urlStrings.compactMap(URL.init(string:))
            guard urls.count == command.urlStrings.count else { return .invalid }
            if let runtime {
                runtime.handle(urls: urls)
                return .accepted
            }
            return enqueuePendingURLs(urls) ? .accepted : .invalid
        default:
            return .unsupported
        }
    }

    private func enqueuePendingURLs(_ urls: [URL]) -> Bool {
        guard pendingURLs.count + urls.count <= Self.maximumPendingURLCount else {
            AppLog.instanceCoordination.warning("Rejected deep links because the launch queue is full")
            return false
        }
        guard urls.allSatisfy({
            AppURLRouter.acceptsDeferredInput($0, acceptedSchemes: acceptedURLSchemes)
        }) else {
            AppLog.instanceCoordination.warning("Rejected invalid deep link during launch")
            return false
        }
        guard AppInstanceCommand.openURLsRequest(pendingURLs + urls).fitsPayloadSizeLimit else {
            AppLog.instanceCoordination.warning("Rejected deep links above the launch payload limit")
            return false
        }
        pendingURLs.append(contentsOf: urls)
        return true
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    func setShowSettingsForRecoveryForTesting(_ action: @escaping () -> Void) {
        showSettingsForTesting = action
    }

    func handleInstanceRecoveryCommandForTesting() -> AppInstanceResponse {
        instanceCommandHandler()(AppInstanceCommand.showSettingsRequest())
    }

    func handleInstanceURLsCommandForTesting(_ urls: [URL]) -> AppInstanceResponse {
        instanceCommandHandler()(AppInstanceCommand.openURLsRequest(urls))
    }

    func pendingURLsForTesting() -> [URL] {
        pendingURLs
    }
    #endif
}

/// Keeps one-shot automation events from observing an incomplete action registry
/// while installed dynamic plugins are still loading or updating.
@MainActor
final class AutomationStartupCoordinator {
    private let startAutomaticRules: () -> Void
    private(set) var hasStarted = false
    private(set) var isPreparing = false

    init(startAutomaticRules: @escaping () -> Void) {
        self.startAutomaticRules = startAutomaticRules
    }

    func actionRegistryDidBecomeReady() {
        guard !hasStarted else { return }
        hasStarted = true
        startAutomaticRules()
    }

    func startAfterActionRegistryPreparation(
        _ prepare: @MainActor () async -> Void
    ) async {
        guard !hasStarted, !isPreparing else { return }
        isPreparing = true
        await prepare()
        isPreparing = false
        actionRegistryDidBecomeReady()
    }
}
