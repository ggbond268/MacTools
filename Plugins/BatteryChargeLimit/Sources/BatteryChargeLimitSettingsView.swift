import SwiftUI
import MacToolsPluginKit

// MARK: - BatteryChargeLimitSettingsView
//
// Custom configuration view shown in the plugin's settings page. Surfaces:
//   1. A larger limit slider with explanation of the "no auto-resume" semantics
//   2. SMC capability diagnostic (which inhibit path the helper found)
//   3. A note about how this differs from macOS Optimized Battery Charging

struct BatteryChargeLimitSettingsView: View {
    @ObservedObject var store: BatteryChargeLimitStore
    var capabilities: BatterySMCCapabilities
    var snapshot: BatterySnapshot

    @State private var sliderValue: Double

    init(store: BatteryChargeLimitStore, capabilities: BatterySMCCapabilities, snapshot: BatterySnapshot) {
        self.store = store
        self.capabilities = capabilities
        self.snapshot = snapshot
        _sliderValue = State(initialValue: Double(store.limitPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            limitSection
            behaviorSection
            compatibilitySection
        }
        .onChange(of: store.limitPercent) { _, newValue in
            sliderValue = Double(newValue)
        }
    }

    // MARK: - Sections

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: "充电上限", icon: "battery.75")

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                HStack(alignment: .firstTextBaseline) {
                    Text("目标电量")
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Spacer()
                    Text("\(Int(sliderValue))%")
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }

                Slider(
                    value: $sliderValue,
                    in: Double(BatteryChargeLimits.minimumPercent)...Double(BatteryChargeLimits.maximumPercent),
                    step: Double(BatteryChargeLimits.percentStep),
                    onEditingChanged: { editing in
                        if !editing {
                            store.setLimitPercent(Int(sliderValue))
                        }
                    }
                )
                .controlSize(.small)

                Text("达到此电量后自动停止充电。")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.host)
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: "充电行为", icon: "bolt.badge.checkmark")

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text("自动维持上限")
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text("电量达到上限后自动停止充电，掉到上限以下约 \(BatteryChargeLimits.resumeHysteresisPercent)% 时自动恢复充电，以此把电量维持在上限附近。点击「暂停充电」可手动停止，手动暂停后不会自动恢复，需再次点击恢复。")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsListRowPadding()
            .pluginSettingsCardBackground(.host)
        }
    }

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: "硬件兼容", icon: "cpu")

            VStack(alignment: .leading, spacing: 0) {
                compatibilityRow(
                    title: "充电控制方式",
                    detail: capabilityDescription
                )

                if capabilities.canForceDischarge {
                    PluginSettingsListDivider()
                    compatibilityRow(
                        title: "强制放电",
                        detail: "支持（CH0I）"
                    )
                }

                if capabilities.isBCLMOnly {
                    PluginSettingsListDivider()
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Label("Intel Mac 说明", systemImage: "info.circle")
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            .foregroundStyle(.orange)
                        Text("当前 Mac 使用 BCLM 固件充电上限，由固件自动把电量维持在上限附近。「暂停充电」依靠把上限临时调低实现，效果可能不如 Apple Silicon 精确。")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsListRowPadding()
                }
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func compatibilityRow(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Spacer()
            Text(detail)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        }
        .pluginSettingsListRowPadding()
    }

    private var capabilityDescription: String {
        if capabilities.hasCHIE {
            return "CHIE (macOS 15+)"
        }
        if capabilities.hasCH0BC {
            return "CH0B + CH0C (Apple Silicon)"
        }
        if capabilities.hasBCLM {
            return "BCLM (Intel)"
        }
        return "未检测到可用的 SMC 充电控制键"
    }
}
