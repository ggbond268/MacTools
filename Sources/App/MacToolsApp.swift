import AppKit
import SwiftUI

@main
struct MacToolsApp: App {
    @StateObject private var pluginHost = PluginHost()

    var body: some Scene {
        MenuBarExtra("MacTools", systemImage: menuBarSymbolName) {
            MenuBarContent(pluginHost: pluginHost)
                .frame(width: menuBarWidth)
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

    private var menuBarWidth: CGFloat {
        let extraWidth = hasVisibleSecondaryPanel
            ? MenuBarPanelLayout.secondaryPanelWidth + MenuBarPanelLayout.panelSpacing
            : 0

        return MenuBarPanelLayout.baseWidth + extraWidth
    }

    private var hasVisibleSecondaryPanel: Bool {
        pluginHost.panelItems.contains(where: itemHasVisibleSecondaryPanel)
    }

    private func itemHasVisibleSecondaryPanel(_ item: PluginPanelItem) -> Bool {
        guard item.detail?.secondaryPanel != nil else {
            return false
        }

        if item.controlStyle == .disclosure {
            return item.isExpanded
        }

        return true
    }
}
