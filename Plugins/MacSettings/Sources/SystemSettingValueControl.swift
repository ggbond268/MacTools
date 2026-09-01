import AppKit
import SwiftUI
import MacToolsPluginKit

struct SystemSettingValueControl: View {
    let schema: SystemSettingValueSchema
    let value: SystemSettingValue
    let enabled: Bool
    let compact: Bool
    var sliderPresentation: SystemSettingSliderPresentation = .standard
    var usesSegmentedPicker: Bool = false
    let onChange: (SystemSettingValue) -> Bool

    var body: some View {
        switch (schema, value) {
        case let (.directoryChoice(options), _):
            Menu {
                ForEach(options) { option in
                    Button(option.title) { _ = onChange(.choice(id: option.id)) }
                }
                Divider()
                Button(MacSettingsStrings.text("Other Folder…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if case let .url(url) = value { panel.directoryURL = url }
                    PluginPresentationSafety.prepareForWindowOrdering()
                    guard panel.runModal() == .OK, let selected = panel.url else { return }
                    _ = onChange(.url(selected))
                }
            } label: {
                Text(directoryTitle(options: options))
                    .lineLimit(1)
            }
            .frame(
                minWidth: compact ? 130 : 180,
                idealWidth: compact ? 150 : 220,
                maxWidth: compact ? 160 : 240
            )
            .help(value.conciseDescription)
            .disabled(!enabled)
            .focusable()
        case let (.boolean, .boolean(isOn)):
            Toggle("", isOn: Binding(get: { isOn }, set: { _ = onChange(.boolean($0)) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!enabled)
                .focusable()
        case let (.choice(options), .choice(selectionID)):
            if usesSegmentedPicker {
                Picker("", selection: Binding(get: { selectionID }, set: { _ = onChange(.choice(id: $0)) })) {
                    ForEach(options) { option in Text(option.title).tag(option.id) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(
                    minWidth: compact ? 160 : 200,
                    idealWidth: compact ? 170 : 240,
                    maxWidth: compact ? 180 : 260
                )
                .disabled(!enabled)
                .focusable()
            } else {
                Picker("", selection: Binding(
                    get: { selectionID },
                    set: { _ = onChange(.choice(id: $0)) }
                )) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(
                    minWidth: compact ? 120 : 150,
                    idealWidth: compact ? 140 : 200,
                    maxWidth: compact ? 150 : 220
                )
                .disabled(!enabled)
                .focusable()
            }
        case let (.integer(range, step), .integer(integer)):
            SystemSettingSliderControl(
                value: Double(integer),
                range: Double(range.lowerBound) ... Double(range.upperBound),
                step: Double(step),
                fractionDigits: 0,
                enabled: enabled,
                presentation: sliderPresentation,
                onCommit: { onChange(.integer(Int($0.rounded()))) }
            )
        case let (.decimal(range, step), .decimal(decimal)):
            SystemSettingSliderControl(
                value: decimal,
                range: range,
                step: step ?? 0.01,
                fractionDigits: step.map { $0 < 1 ? 1 : 0 } ?? 2,
                enabled: enabled,
                presentation: sliderPresentation,
                onCommit: { onChange(.decimal($0)) }
            )
        case (.url, .url(let url)):
            Button(url.lastPathComponent.isEmpty ? MacSettingsStrings.text("Choose…") : url.lastPathComponent) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.directoryURL = url
                PluginPresentationSafety.prepareForWindowOrdering()
                guard panel.runModal() == .OK, let selected = panel.url else { return }
                _ = onChange(.url(selected))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: 180)
            .lineLimit(1)
            .disabled(!enabled)
            .focusable()
        default:
            Text(value.conciseDescription)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(.secondary)
        }
    }

    private func directoryTitle(options: [SystemSettingChoice]) -> String {
        switch value {
        case let .choice(id): options.first(where: { $0.id == id })?.title ?? MacSettingsStrings.format("Current Location (%@)", "\(id)")
        case let .url(url): url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        default: value.conciseDescription
        }
    }
}

enum SystemSettingSliderPresentation {
    case standard
    case pointerSize
}

private struct SystemSettingSliderControl: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let enabled: Bool
    let presentation: SystemSettingSliderPresentation
    let onCommit: (Double) -> Bool

    @State private var draft: Double

    init(
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int,
        enabled: Bool,
        presentation: SystemSettingSliderPresentation,
        onCommit: @escaping (Double) -> Bool
    ) {
        self.value = value
        self.range = range
        self.step = step
        self.fractionDigits = fractionDigits
        self.enabled = enabled
        self.presentation = presentation
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        Group {
            switch presentation {
            case .standard:
                standardSlider
            case .pointerSize:
                pointerSizeSlider
            }
        }
        .disabled(!enabled)
        .onChange(of: value) { draft = value }
    }

    private var standardSlider: some View {
        HStack(spacing: 8) {
            slider
                .accessibilityHidden(true)
                .frame(minWidth: 90, idealWidth: 120, maxWidth: 150)
            Text(formattedDraft)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .frame(width: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(formattedDraft)
        .accessibilityAdjustableAction(adjustAccessibilityValue)
    }

    private var pointerSizeSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            slider
                .accessibilityHidden(true)
                .frame(minWidth: 130, idealWidth: 170, maxWidth: 210)

            Image(systemName: "cursorarrow")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MacSettingsStrings.text("Pointer Size"))
        .accessibilityValue(formattedDraft)
        .accessibilityAdjustableAction(adjustAccessibilityValue)
    }

    private var slider: some View {
        Slider(value: $draft, in: range, step: step) { editing in
            if !editing, !onCommit(draft) { draft = value }
        }
    }

    private var formattedDraft: String {
        draft.formatted(.number.precision(.fractionLength(fractionDigits)).locale(PluginRuntimeLocalization.locale))
    }

    private func adjustAccessibilityValue(_ direction: AccessibilityAdjustmentDirection) {
        guard enabled else { return }
        let delta = direction == .increment ? step : -step
        let adjusted = min(max(draft + delta, range.lowerBound), range.upperBound)
        guard adjusted != draft else { return }
        draft = adjusted
        if !onCommit(adjusted) {
            draft = value
        }
    }
}
