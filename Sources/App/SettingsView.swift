import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var pluginHost: PluginHost

    var body: some View {
        TabView(selection: $pluginHost.selectedSettingsDestination) {
            GeneralSettingsView(pluginHost: pluginHost)
                .tag(SettingsDestination.general)
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            ShortcutSettingsView(pluginHost: pluginHost)
                .tag(SettingsDestination.shortcuts)
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }

            AboutSettingsView()
                .tag(SettingsDestination.about)
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 580)
        .frame(minHeight: 420)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var pluginHost: PluginHost

    var body: some View {
        Form {
            ForEach(pluginHost.permissionCards) { card in
                Section {
                    LabeledContent("当前状态") {
                        Label {
                            Text(card.statusText)
                        } icon: {
                            Image(systemName: card.statusSystemImage)
                                .foregroundStyle(statusColor(for: card.statusTone))
                        }
                    }

                    Text(card.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let footnote = card.footnote {
                        Text(footnote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer()

                        Button(card.buttonTitle) {
                            pluginHost.performPermissionAction(
                                pluginID: card.pluginID,
                                permissionID: card.permissionID
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text(card.title)
                }
            }

            ForEach(pluginHost.settingsCards) { card in
                Section {
                    LabeledContent("当前状态") {
                        Label {
                            Text(card.statusText)
                        } icon: {
                            Image(systemName: card.statusSystemImage)
                                .foregroundStyle(statusColor(for: card.statusTone))
                        }
                    }

                    Text(card.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let footnote = card.footnote {
                        Text(footnote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let buttonTitle = card.buttonTitle, let actionID = card.actionID {
                        HStack {
                            Spacer()

                            Button(buttonTitle) {
                                pluginHost.performSettingsAction(pluginID: card.pluginID, actionID: actionID)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    Text(card.title)
                }
            }

            Section {
                FeatureManagementTableView(
                    items: pluginHost.featureManagementItems,
                    onVisibilityChange: { pluginID, isVisible in
                        pluginHost.setFeatureVisibility(isVisible, for: pluginID)
                    },
                    onMove: { pluginID, targetOffset in
                        pluginHost.moveFeatureManagementItem(id: pluginID, toOffset: targetOffset)
                    }
                )
                .frame(height: featureManagementListHeight)
            } header: {
                Text("功能")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pluginHost.refreshAll()
        }
    }

    private func statusColor(for tone: PluginStatusTone) -> Color {
        switch tone {
        case .neutral:
            return .secondary
        case .positive:
            return .green
        case .caution:
            return .orange
        }
    }

    private var featureManagementListHeight: CGFloat {
        FeatureManagementTableView.preferredHeight(for: pluginHost.featureManagementItems.count)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            AppIconPreview()

            Text(AppMetadata.appName)
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 18)

            Text("版本 \(AppMetadata.versionDescription)")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Text(AppMetadata.aboutDescription)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 28)

            VStack(spacing: 8) {
                Text(AppMetadata.authorDescription)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Link(AppMetadata.repositoryDisplayName, destination: AppMetadata.repositoryURL)
                    .font(.title3)
            }
            .padding(.top, 28)

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
    }
}

private struct AppIconPreview: View {
    var body: some View {
        Group {
            if let appIcon = AppMetadata.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
            } else {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundStyle(.secondary)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
