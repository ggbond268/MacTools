import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @StateObject private var pluginHost = PluginHost()
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        MenuBarExtra("MacTools", systemImage: menuBarSymbolName) {
            MenuBarContent(pluginHost: pluginHost)
                .onAppear {
                    pluginHost.refreshAll()
                }
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: "settings") {
            SettingsView(pluginHost: pluginHost, appUpdater: appUpdater)
        }
        .defaultSize(width: 580, height: 420)
        .windowResizability(.contentSize)
    }

    private var menuBarSymbolName: String {
        pluginHost.hasActivePlugin
            ? "sparkles.rectangle.stack.fill"
            : "sparkles.rectangle.stack"
    }
}
