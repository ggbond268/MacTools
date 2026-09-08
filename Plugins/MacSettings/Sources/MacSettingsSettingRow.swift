import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct MacSettingRow: View {
    let record: SystemSettingRecord
    let state: SystemSettingRowState?
    let canEditSettings: Bool
    let isFavorite: Bool
    let showsCategory: Bool
    let isKeyboardFocused: Bool
    let focusedElement: FocusState<MacSettingsWorkspaceFocus?>.Binding
    let onApply: (SystemSettingValue) -> Bool
    let onFavorite: () -> Void
    let favoriteIndex: Int?
    let favoriteCount: Int
    let onMoveFavorite: (Int) -> Void
    let onOpenSystemSettings: () -> Void
    let onOpenProviderSettings: () -> Void
    let canRetry: Bool
    let onRetry: () -> Void
    let onMoveFocus: (Bool) -> Void

    @State private var detailsExpanded = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: detailsExpanded ? 10 : 0) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Button {
                    toggleDetails()
                } label: {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(record.definition.title)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .lineLimit(2)
                        if showsCategory || showsAvailabilityBadge {
                            HStack(spacing: 6) {
                                if showsCategory {
                                    Text(record.definition.category.title)
                                        .font(PluginSettingsTheme.Typography.rowDescription)
                                        .foregroundStyle(.secondary)
                                }
                                availabilityBadge
                            }
                        }
                        if let error = state?.errorMessage {
                            Text(error)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .layoutPriority(1)
                .accessibilityLabel(record.definition.title)
                .accessibilityHint(
                    detailsExpanded
                        ? MacSettingsStrings.format("Hide details for %@", "\(record.definition.title)")
                        : MacSettingsStrings.format("Show details for %@", "\(record.definition.title)")
                )

                Group {
                    if let phase = state?.operationPhase {
                        Text(phase.title)
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                    } else if state?.isLoading == true || state?.isApplying == true {
                        ProgressView().controlSize(.small)
                    } else if canRetry {
                        HStack {
                            Button(MacSettingsStrings.text("Retry"), action: onRetry)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!canEditSettings)
                            settingControl
                        }
                    } else {
                        settingControl
                    }
                }
                .frame(minWidth: 230, idealWidth: 280, maxWidth: 300, alignment: .trailing)
                .accessibilityLabel(record.definition.title)

                favoriteButton

                Button {
                    toggleDetails()
                } label: {
                    Image(systemName: detailsExpanded ? "chevron.up" : "chevron.down")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .frame(width: 24)
                .focusable(false)
                .accessibilityHidden(true)
            }

            if detailsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.definition.description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    Text(detailText)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button {
                            onFavorite()
                        } label: {
                            Label(
                                isFavorite ? MacSettingsStrings.text("Unpin from Top") : MacSettingsStrings.text("Pin to Top"),
                                systemImage: isFavorite ? "pin.slash" : "pin"
                            )
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(MacSettingsStrings.text("Pin to the top and the Pinned list. The first four also appear in the Feature Panel."))

                        if let favoriteIndex {
                            Button(MacSettingsStrings.text("Move Up")) { onMoveFavorite(-1) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(favoriteIndex == 0)
                            Button(MacSettingsStrings.text("Move Down")) { onMoveFavorite(1) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(favoriteIndex == favoriteCount - 1)
                        }

                        if record.definition.destination?.url != nil {
                            Button(MacSettingsStrings.text("Open in System Settings"), action: onOpenSystemSettings)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    if isFavorite {
                        Text(MacSettingsStrings.text("Pinned to the top. The first four also appear in the Feature Panel."))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .focusable(true, interactions: .activate)
        .focused(focusedElement, equals: .setting(record.id))
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: onMoveFocus(false)
            case .down: onMoveFocus(true)
            default: break
            }
        }
        .onKeyPress(.upArrow) {
            onMoveFocus(false)
            return .handled
        }
        .onKeyPress(.downArrow) {
            onMoveFocus(true)
            return .handled
        }
        .onKeyPress(.return) {
            toggleDetails()
            return .handled
        }
        .onKeyPress(.space) {
            toggleDetails()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(record.definition.title)
        .accessibilityValue(accessibilityValueDescription)
        .accessibilityHint(record.definition.description)
        .animation(.easeOut(duration: 0.14), value: detailsExpanded)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isKeyboardFocused)
    }

    private var rowBackground: Color {
        if isKeyboardFocused { return Color.accentColor.opacity(0.10) }
        if detailsExpanded { return Color.secondary.opacity(0.08) }
        if isHovered { return Color.secondary.opacity(0.05) }
        return .clear
    }

    private func toggleDetails() {
        detailsExpanded.toggle()
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if isFavorite {
            Button(action: onFavorite) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .focusable(true, interactions: .activate)
            .frame(width: 28, height: 28)
            .help(MacSettingsStrings.text("Unpin from Top"))
            .accessibilityLabel(MacSettingsStrings.text("Unpin from Top"))
        } else {
            Button(action: onFavorite) {
                Image(systemName: "pin")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .focusable(true, interactions: .activate)
            .frame(width: 28, height: 28)
            .help(MacSettingsStrings.text("Pin to Top"))
            .accessibilityLabel(MacSettingsStrings.text("Pin to Top"))
        }
    }

    @ViewBuilder
    private var settingControl: some View {
        let availability = state?.availability ?? .unsupported(MacSettingsStrings.text("Could not read the status."))
        if case let .providerUnavailable(reason) = availability {
            Button(MacSettingsStrings.text("View Plugin"), action: onOpenProviderSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(reason)
        } else if state?.errorMessage != nil, record.definition.destination != nil {
            Button(MacSettingsStrings.text("Open System Settings"), action: onOpenSystemSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if isDirectlyControllable(availability), let value = state?.value {
            SystemSettingValueControl(
                schema: record.definition.schema,
                value: value,
                enabled: state?.isApplying != true && canEditSettings,
                compact: false,
                sliderPresentation: record.id == "accessibility.pointer-size"
                    ? .pointerSize
                    : .standard,
                usesSegmentedPicker: record.id == "appearance.dark-mode",
                onChange: onApply
            )
        } else {
            switch availability {
            case .guidedManual:
                if record.definition.destination?.url != nil {
                    Button(MacSettingsStrings.text("Open System Settings"), action: onOpenSystemSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Text(MacSettingsStrings.text("Manual Setup Required")).foregroundStyle(.secondary)
                }
            case .permissionMissing:
                Button(MacSettingsStrings.text("Grant Permission"), action: onOpenSystemSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .providerUnavailable:
                Button(MacSettingsStrings.text("View Plugin"), action: onOpenProviderSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            default:
                Text(statusText(for: availability))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var availabilityBadge: some View {
        if let state {
            switch state.availability {
            case .requiresLogout:
                badge(MacSettingsStrings.text("Log Out and Back In"), color: .orange)
            case .requiresRestart:
                badge(MacSettingsStrings.text("Reopen Related App"), color: .orange)
            case .guidedManual:
                badge(MacSettingsStrings.text("Manual"), color: .blue)
            case .hardwareUnavailable, .providerUnavailable, .permissionMissing:
                badge(MacSettingsStrings.text("Unavailable"), color: .orange)
            case .managedOnly:
                badge(MacSettingsStrings.text("Managed"), color: .purple)
            case .unsupported, .systemVersionUnsupported:
                badge(MacSettingsStrings.text("Unsupported"), color: .secondary)
            case .available:
                if state.verification == .unverified {
                    badge(MacSettingsStrings.text("Unverified"), color: .orange)
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var showsAvailabilityBadge: Bool {
        guard let state else { return false }
        switch state.availability {
        case .available:
            return state.verification == .unverified
        case .requiresLogout, .requiresRestart, .guidedManual, .hardwareUnavailable,
             .providerUnavailable, .permissionMissing, .managedOnly, .unsupported,
             .systemVersionUnsupported:
            return true
        }
    }

    private var detailText: String {
        let execution = switch record.definition.executionClass {
        case .directVerified: MacSettingsStrings.text("Can be changed and verified directly")
        case .directAppliesNextUse: MacSettingsStrings.text("Saved and verified; takes effect on next use")
        case .directRequiresLogout: MacSettingsStrings.text("Can be changed directly; takes full effect after logging out and back in")
        case .directRequiresRestart: MacSettingsStrings.text("Can be changed directly; takes full effect after reopening the related app")
        case .existingPluginProvider: MacSettingsStrings.text("Applied and verified by an existing MacTools plugin")
        case .guidedManual: MacSettingsStrings.text("Must be completed manually in System Settings")
        case .hardwareDependent: MacSettingsStrings.text("Requires supported hardware")
        case .managedOnly: MacSettingsStrings.text("Can only be managed by your organization")
        case .unsupported: MacSettingsStrings.text("Direct changes are not currently supported")
        }
        return "\(execution).\n\(record.definition.implementationNote)"
    }

    private var accessibilityValueDescription: String {
        let value = state?.value.map(record.definition.displayDescription(for:)) ?? MacSettingsStrings.text("Unknown")
        let favorite = isFavorite ? MacSettingsStrings.text(", pinned") : ""
        return MacSettingsStrings.format("Current value %@%@, %@", "\(value)", "\(favorite)", "\(statusText(for: state?.availability ?? .unsupported(MacSettingsStrings.text("Could not read the status."))))")
    }

    private func isDirectlyControllable(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart: true
        default: false
        }
    }

    private func statusText(for availability: SystemSettingAvailability) -> String {
        switch availability {
        case .available: MacSettingsStrings.text("Available")
        case .requiresLogout: MacSettingsStrings.text("Log Out and Back In")
        case .requiresRestart: MacSettingsStrings.text("Reopen Related App")
        case let .providerUnavailable(reason): reason
        case .hardwareUnavailable: MacSettingsStrings.text("Hardware Unavailable")
        case .permissionMissing: MacSettingsStrings.text("Permission Required")
        case .guidedManual: MacSettingsStrings.text("Manual Setup")
        case .managedOnly: MacSettingsStrings.text("Managed by Your Organization")
        case .unsupported: MacSettingsStrings.text("Unsupported")
        case .systemVersionUnsupported: MacSettingsStrings.text("Unsupported macOS Version")
        }
    }
}
