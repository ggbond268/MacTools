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
    let shortcutItems: [ShortcutSettingsItem]
    let actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration?
    let shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration]

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
        let configuredItemIDs = shortcutSettingsGroups.reduce(into: Set<String>()) { result, group in
            result.formUnion(group.shortcutDefinitionIDs.map { "\(pluginID).shortcut.\($0)" })
        }
        return shortcutItems.filter { item in
            if configuredItemIDs.contains(item.id) {
                return false
            }
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
