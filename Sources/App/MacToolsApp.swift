import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(MacToolsAppDelegate.self) private var appDelegate

    init() {
        AppLanguagePreference.applyStoredPreference()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MacToolsAppDelegate: NSObject, NSApplicationDelegate {
    private let pluginHost = PluginHost(loadDynamicPluginsOnInit: false)
    private let appUpdater = AppUpdater()
    private let menuBarIconSettings = MenuBarIconSettings()
    private let menuBarIconGallery = MenuBarIconGalleryLibrary()
    private let launchAtLoginController = LaunchAtLoginController()
    private let pluginAutomaticUpdateVersionStore = PluginAutomaticUpdateVersionStore()
    private var windowRouter: AppWindowRouter?
    private var statusItemController: MenuBarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearancePreference.applyStoredPreference()
        launchAtLoginController.refreshStatus()

        let windowRouter = AppWindowRouter(
            pluginHost: pluginHost,
            appUpdater: appUpdater,
            menuBarIconSettings: menuBarIconSettings,
            menuBarIconGallery: menuBarIconGallery,
            launchAtLoginController: launchAtLoginController
        )
        self.windowRouter = windowRouter
        statusItemController = MenuBarStatusItemController(
            pluginHost: pluginHost,
            windowRouter: windowRouter,
            iconSettings: menuBarIconSettings
        )

        bootstrapDynamicPlugins()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // The Finder Sync extension forwards file-creating actions here via the
        // mactools:// scheme so the non-sandboxed host app performs them.
        for url in urls {
            FinderContextMenuRequestHandler.handle(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.dismissPanels()
        pluginHost.dynamicPluginManager?.deactivateAll()
    }

    private func bootstrapDynamicPlugins() {
        let currentAppVersion = AppMetadata.versionDescription

        guard pluginHost.hasInstalledDynamicPlugins else {
            pluginHost.loadDynamicPluginsIfNeeded()
            pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                currentAppVersion: currentAppVersion
            )
            return
        }

        guard pluginAutomaticUpdateVersionStore.needsAutomaticUpdateCheck(
            currentAppVersion: currentAppVersion
        ) else {
            pluginHost.loadDynamicPluginsIfNeeded()
            return
        }

        Task { @MainActor in
            await pluginHost.automaticUpdateInstalledPluginsBeforeLoading()

            pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                currentAppVersion: currentAppVersion
            )
        }
    }
}
