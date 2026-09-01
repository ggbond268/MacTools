import SwiftUI
import MacToolsPluginKit

struct PluginSettingsPageItem: Identifiable {
    let id: String
    let pluginID: String
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let installedAt: Date?
    let page: PluginSettingsPage?
    let permissionCards: [PluginPermissionCard]
    let missingPermissionCardIDs: Set<String>
    let shortcutItems: [ShortcutSettingsItem]
    let actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration?

    var layout: PluginSettingsLayout {
        page?.body.layout ?? .form
    }

    var sections: [PluginSettingsSection] {
        guard case let .form(sections) = page?.body else {
            return []
        }
        return sections
    }

    var hasPluginContent: Bool {
        page != nil
    }

    var missingPermissionCards: [PluginPermissionCard] {
        permissionCards.filter { missingPermissionCardIDs.contains($0.id) }
    }

    var workspaceScrolling: PluginSettingsWorkspaceScrolling {
        guard case let .workspace(workspace) = page?.body else {
            return .selfManaged
        }
        return workspace.scrolling
    }

    var integratedShortcutGroupIDs: Set<String> {
        page?.body.integratedShortcutGroupIDs ?? []
    }

    var remainingShortcutItems: [ShortcutSettingsItem] {
        shortcutItems.filter { item in
            guard let groupID = item.settingsGroupID else {
                return true
            }
            return !integratedShortcutGroupIDs.contains(groupID)
        }
    }

}

struct PluginSettingsContentViewItem: Identifiable {
    let id: String
    let content: AnyView
}
