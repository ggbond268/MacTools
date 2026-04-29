import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var appUpdater: AppUpdater

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

            AboutSettingsView(appUpdater: appUpdater)
                .tag(SettingsDestination.about)
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 580)
        .frame(minHeight: 420)
    }
}

private struct PermissionSettingsRow: View {
    let card: PluginPermissionCard
    let statusColor: Color
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: card.statusSystemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(card.title)
                        .font(.system(size: 12, weight: .semibold))

                    Text(card.statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                }

                Text(card.description)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let footnote = card.footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(card.buttonTitle, action: onAction)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var pluginHost: PluginHost

    var body: some View {
        Form {
            if !pluginHost.permissionCards.isEmpty {
                Section {
                    ForEach(pluginHost.permissionCards) { card in
                        PermissionSettingsRow(
                            card: card,
                            statusColor: statusColor(for: card.statusTone),
                            onAction: {
                                pluginHost.performPermissionAction(
                                    pluginID: card.pluginID,
                                    permissionID: card.permissionID
                                )
                            }
                        )
                    }
                } header: {
                    Text("授权")
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
    @StateObject private var updateViewModel: AboutUpdateViewModel

    init(appUpdater: AppUpdater) {
        _updateViewModel = StateObject(
            wrappedValue: AboutUpdateViewModel(updater: appUpdater)
        )
    }

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

            AboutUpdateCard(viewModel: updateViewModel)
                .padding(.top, 28)
                .frame(maxWidth: 420)

            Text(AppMetadata.aboutDescription)
                .font(.title3)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, 28)

            VStack(spacing: 0) {
                Link(AppMetadata.repositoryDisplayName, destination: AppMetadata.repositoryURL)
                    .font(.title3)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
    }
}

private struct AboutUpdateCard: View {
    private enum Layout {
        static let verticalSpacing: CGFloat = 12
        static let statusMinHeight: CGFloat = 16
    }

    @ObservedObject var viewModel: AboutUpdateViewModel

    var body: some View {
        VStack(spacing: Layout.verticalSpacing) {
            Button(viewModel.primaryButtonTitle) {
                Task {
                    await viewModel.performPrimaryAction()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isPrimaryButtonDisabled)

            Text(statusText ?? " ")
                .font(.footnote)
                .foregroundStyle(viewModel.statusColor)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: Layout.statusMinHeight, alignment: .top)
                .opacity(statusText == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String? {
        switch viewModel.state {
        case .idle:
            return nil
        default:
            return viewModel.statusDetail ?? viewModel.statusHeadline
        }
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
