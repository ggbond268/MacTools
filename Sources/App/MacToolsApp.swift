import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @StateObject private var pluginHost = PluginHost()

    var body: some Scene {
        MenuBarExtra("MacTools", systemImage: menuBarSymbolName) {
            MenuBarContent(pluginHost: pluginHost)
                .frame(width: 312)
                .onAppear {
                    pluginHost.refreshAll()
                }
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: "settings") {
            SettingsView(pluginHost: pluginHost)
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
