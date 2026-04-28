import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(MacToolsAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MacToolsAppDelegate: NSObject, NSApplicationDelegate {
    private let pluginHost = PluginHost()
    private let appUpdater = AppUpdater()
    private var windowRouter: AppWindowRouter?
    private var statusItemController: MenuBarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowRouter = AppWindowRouter(pluginHost: pluginHost, appUpdater: appUpdater)
        self.windowRouter = windowRouter
        statusItemController = MenuBarStatusItemController(
            pluginHost: pluginHost,
            windowRouter: windowRouter
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.dismissPanels()
    }
}
