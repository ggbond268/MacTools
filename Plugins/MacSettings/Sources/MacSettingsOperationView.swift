import SwiftUI
import MacToolsPluginKit

struct MacSettingsOperationBanner: View {
    @ObservedObject var controller: MacSettingsController

    var body: some View {
        HStack(spacing: 12) {
            if let progress = controller.operationProgress {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MacSettingsStrings.format("Processed %@ of %@", "\(progress.completed)", "\(progress.total)"))
                        .monospacedDigit()
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        .frame(width: 150)
                }
                Text(activeTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
                Text(MacSettingsStrings.text("Reading current values…"))
                Spacer()
            }
            Button(MacSettingsStrings.text("Stop")) { controller.cancelOperation() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(MacSettingsStrings.text("Stop after the current setting finishes verification or restoration. No further changes will start."))
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .frame(height: 42)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .accessibilityIdentifier("mac-settings.operation-progress")
        Divider()
    }

    private var activeTitle: String {
        guard let progress = controller.operationProgress,
              let id = progress.activeSettingID else { return MacSettingsStrings.text("Preparing results…") }
        let title = controller.catalog[id]?.definition.title ?? id.rawValue
        return "\(title) · \(progress.phase?.title ?? MacSettingsStrings.text("Processing"))"
    }
}

struct MacSettingsRecoveryView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var keepingID: SystemSettingID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(controller.pendingRecoveries.isEmpty ? MacSettingsStrings.text("Recovery Records Not Saved") : MacSettingsStrings.text("Restoration Incomplete"), systemImage: "exclamationmark.triangle")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.orange)
                if !controller.pendingRecoveries.isEmpty {
                    Text(MacSettingsStrings.text("Original snapshots have been retained. Resolve these items before applying other changes."))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                }
                if let error = controller.recoveryPersistenceError {
                    Text(error)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                    Button(MacSettingsStrings.text("Retry Saving Recovery Records")) { controller.retrySavingRecoveries() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!controller.canResolveRecovery)
                }
                ForEach(controller.pendingRecoveries.values.sorted { $0.id.rawValue < $1.id.rawValue }) { recovery in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(controller.catalog[recovery.id]?.definition.title ?? recovery.id.rawValue)
                                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            Spacer()
                            Button(MacSettingsStrings.text("Retry Restoration")) { controller.retryRecovery(recovery.id) }
                            Button(MacSettingsStrings.text("Keep Current Values…")) { keepingID = recovery.id }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!controller.canResolveRecovery)
                        Text(recovery.message)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        DisclosureGroup(MacSettingsStrings.text("Compare Current and Original Values")) {
                            Text(recovery.differences.isEmpty
                                 ? MacSettingsStrings.text("Preference values match, but restoration has not been confirmed.")
                                 : recovery.differences.joined(separator: "\n"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                    }
                }
            }
            .padding(18)
        }
        .frame(maxHeight: 230)
        .pluginSettingsCardBackground(.recessed)
        .accessibilityIdentifier("mac-settings.pending-recovery")
        .confirmationDialog(MacSettingsStrings.text("Keep current values and abandon this restoration?"), isPresented: Binding(
            get: { keepingID != nil }, set: { if !$0 { keepingID = nil } }
        ), titleVisibility: .visible) {
            Button(MacSettingsStrings.text("Keep Current Values"), role: .destructive) {
                if let id = keepingID { controller.keepCurrentValues(id) }
                keepingID = nil
            }
            Button(MacSettingsStrings.text("Cancel"), role: .cancel) { keepingID = nil }
        } message: {
            Text(MacSettingsStrings.text("This does not change macOS settings, but discards the retained recovery snapshot for this item."))
        }
    }
}
