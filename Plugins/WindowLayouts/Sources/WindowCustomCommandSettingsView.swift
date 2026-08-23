import CoreGraphics
import SwiftUI
import MacToolsPluginKit

struct WindowCustomCommandPreviewLayout {
    private static let referenceScreenSize = CGSize(width: 1_440, height: 900)

    let command: WindowCustomCommand

    func windowFrame(in screenSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return .zero }

        let windowSize = CGSize(
            width: screenSize.width * fraction(
                for: command.width,
                referenceLength: Self.referenceScreenSize.width
            ),
            height: screenSize.height * fraction(
                for: command.height,
                referenceLength: Self.referenceScreenSize.height
            )
        )
        let factors = anchorFactors(command.anchor)
        let origin = CGPoint(
            x: (screenSize.width - windowSize.width) * factors.x
                + screenSize.width * command.offsetX / Self.referenceScreenSize.width,
            y: (screenSize.height - windowSize.height) * factors.y
                + screenSize.height * command.offsetY / Self.referenceScreenSize.height
        )
        return CGRect(origin: origin, size: windowSize)
    }

    private func fraction(
        for dimension: WindowLayoutDimension,
        referenceLength: CGFloat
    ) -> CGFloat {
        let value: CGFloat = switch dimension {
        case .current: 0.6
        case let .points(points): points / referenceLength
        case let .fraction(fraction): fraction
        }
        return min(max(value, 0.05), 1)
    }

    private func anchorFactors(_ anchor: WindowLayoutAnchor) -> CGPoint {
        switch anchor {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .left: CGPoint(x: 0, y: 0.5)
        case .center: CGPoint(x: 0.5, y: 0.5)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        }
    }
}

@MainActor
struct WindowCustomCommandHeaderActions: View {
    let commandID: UUID
    let duplicateTitle: String
    let deleteTitle: String
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button(action: onDuplicate) {
                Image(systemName: "doc.on.doc")
                    .frame(
                        width: PluginSettingsTheme.Size.rowIcon,
                        height: PluginSettingsTheme.Size.rowIcon
                    )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(duplicateTitle)
            .accessibilityLabel(duplicateTitle)
            .accessibilityIdentifier(
                "mactools.window-layouts.custom.\(commandID.uuidString.lowercased()).duplicate"
            )

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(
                        width: PluginSettingsTheme.Size.rowIcon,
                        height: PluginSettingsTheme.Size.rowIcon
                    )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(deleteTitle)
            .accessibilityLabel(deleteTitle)
            .accessibilityIdentifier(
                "mactools.window-layouts.custom.\(commandID.uuidString.lowercased()).delete"
            )
        }
    }
}

@MainActor
struct WindowCustomCommandSettingsView: View {
    private enum DimensionAxis: Equatable {
        case width
        case height
    }

    @ObservedObject var plugin: WindowLayoutsPlugin
    let commandID: UUID

    @State private var draft: WindowCustomCommand
    @FocusState private var isNameFocused: Bool

    init(plugin: WindowLayoutsPlugin, command: WindowCustomCommand) {
        self.plugin = plugin
        self.commandID = command.id
        _draft = State(initialValue: command)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewAndShortcutRow
            divider
            nameRow
            divider
            dimensionModeRow(.width)
            divider
            dimensionValueRow(.width)
            divider
            dimensionModeRow(.height)
            divider
            dimensionValueRow(.height)
            divider
            anchorRow
            divider
            offsetRow(.width)
            divider
            offsetRow(.height)
            divider
            runLinkRow
        }
        .onChange(of: plugin.customCommandSettingsRevision) { _, _ in
            synchronizeDraftIfNeeded()
        }
    }

    private var previewAndShortcutRow: some View {
        HStack(
            alignment: .center,
            spacing: PluginSettingsTheme.Spacing.cardContent
        ) {
            VStack(
                alignment: .leading,
                spacing: PluginSettingsTheme.Spacing.controlCluster
            ) {
                Label(
                    plugin.localizedKey("settings.custom.preview", "布局预览"),
                    systemImage: "rectangle.on.rectangle"
                )
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                WindowCustomLayoutPreview(command: draft)
                    .frame(width: 184, height: 112)
                    .accessibilityLabel(previewSummary)
            }

            VStack(
                alignment: .leading,
                spacing: PluginSettingsTheme.Spacing.sectionHeaderContent
            ) {
                Text(previewSummary)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text(plugin.localizedKey(
                    "settings.custom.shortcut",
                    "全局快捷键"
                ))
                .font(PluginSettingsTheme.Typography.rowTitle)

                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    PluginShortcutRecorder(
                        title: draft.name,
                        displayText: shortcutDisplayText,
                        minWidth: PluginSettingsTheme.Size.shortcutRecorderWidth,
                        onRecord: { binding in
                            plugin.recordCustomCommandShortcut(binding, for: commandID)
                        }
                    )
                    .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth)
                    .accessibilityIdentifier(
                        "mactools.window-layouts.custom.\(commandID.uuidString.lowercased()).shortcut"
                    )

                    if shortcutBinding != nil {
                        Button {
                            plugin.clearCustomCommandShortcut(for: commandID)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .pluginSettingsRowIconStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(plugin.localizedKey(
                            "settings.custom.shortcut.clear",
                            "清除快捷键"
                        ))
                        .accessibilityLabel(plugin.localizedKey(
                            "settings.custom.shortcut.clear",
                            "清除快捷键"
                        ))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var nameRow: some View {
        settingsRow(
            title: plugin.localizedKey("settings.custom.name", "名称")
        ) {
            TextField("", text: $draft.name)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                .focused($isNameFocused)
                .onSubmit(commitDraft)
                .onChange(of: isNameFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused {
                        commitDraft()
                    }
                }
        }
    }

    private func dimensionModeRow(_ axis: DimensionAxis) -> some View {
        settingsRow(title: dimensionModeTitle(axis)) {
            Picker("", selection: dimensionModeBinding(axis)) {
                Text(plugin.localizedKey(
                    "settings.dimension.current",
                    "保持当前"
                ))
                .tag("current")
                Text(plugin.localizedKey(
                    "settings.dimension.fraction",
                    "屏幕比例"
                ))
                .tag("fraction")
                Text(plugin.localizedKey(
                    "settings.dimension.points",
                    "固定点数"
                ))
                .tag("points")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
        }
    }

    private func dimensionValueRow(_ axis: DimensionAxis) -> some View {
        settingsRow(title: dimensionValueTitle(axis)) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                PluginSettingsSlider(
                    value: dimensionValueBinding(axis),
                    in: dimensionRange(axis),
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing { commitDraft() }
                    }
                )

                Text(dimensionValueText(axis))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .trailing)
            }
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
            .disabled(dimensionMode(axis) == "current")
        }
    }

    private var anchorRow: some View {
        settingsRow(
            title: plugin.localizedKey("settings.custom.anchor", "固定位置")
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { draft.anchor },
                    set: { anchor in
                        draft.anchor = anchor
                        commitDraft()
                    }
                )
            ) {
                ForEach(WindowLayoutAnchor.allCases, id: \.rawValue) { anchor in
                    Text(plugin.anchorTitle(anchor)).tag(anchor)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
        }
    }

    private func offsetRow(_ axis: DimensionAxis) -> some View {
        let isHorizontal = axis == .width
        return settingsRow(
            title: plugin.localizedKey(
                isHorizontal ? "settings.custom.offsetX" : "settings.custom.offsetY",
                isHorizontal ? "水平偏移" : "垂直偏移"
            )
        ) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                PluginSettingsSlider(
                    value: offsetBinding(axis),
                    in: -500...500,
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing { commitDraft() }
                    }
                )

                Text("\(Int(isHorizontal ? draft.offsetX : draft.offsetY)) pt")
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
        }
    }

    private var runLinkRow: some View {
        settingsRow(
            title: plugin.localizedKey("settings.custom.external", "允许 Run Link")
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { draft.allowExternalInvocation },
                    set: { isAllowed in
                        draft.allowExternalInvocation = isAllowed
                        commitDraft()
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var divider: some View {
        PluginSettingsListDivider()
    }

    private func settingsRow<Control: View>(
        title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(
            alignment: .center,
            spacing: PluginSettingsTheme.Spacing.rowContentControl
        ) {
            Text(title)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .layoutPriority(1)

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var shortcutBinding: ShortcutBinding? {
        plugin.customCommandShortcutBinding(for: commandID)
    }

    private var shortcutDisplayText: String {
        shortcutBinding.map { ShortcutFormatter.displayString(for: $0) } ?? ""
    }

    private var previewSummary: String {
        "\(dimensionSummary(draft.width)) × \(dimensionSummary(draft.height)) · "
            + plugin.anchorTitle(draft.anchor)
    }

    private func dimensionSummary(_ dimension: WindowLayoutDimension) -> String {
        switch dimension {
        case .current:
            plugin.localizedKey("settings.dimension.current", "保持当前")
        case let .fraction(value):
            "\(Int((value * 100).rounded()))%"
        case let .points(value):
            "\(Int(value.rounded())) pt"
        }
    }

    private func dimensionModeTitle(_ axis: DimensionAxis) -> String {
        switch axis {
        case .width:
            plugin.localizedKey("settings.custom.widthMode", "宽度模式")
        case .height:
            plugin.localizedKey("settings.custom.heightMode", "高度模式")
        }
    }

    private func dimensionValueTitle(_ axis: DimensionAxis) -> String {
        switch axis {
        case .width:
            plugin.localizedKey("settings.custom.width", "宽度")
        case .height:
            plugin.localizedKey("settings.custom.height", "高度")
        }
    }

    private func dimension(_ axis: DimensionAxis) -> WindowLayoutDimension {
        switch axis {
        case .width: draft.width
        case .height: draft.height
        }
    }

    private func setDimension(
        _ dimension: WindowLayoutDimension,
        axis: DimensionAxis
    ) {
        switch axis {
        case .width: draft.width = dimension
        case .height: draft.height = dimension
        }
    }

    private func dimensionMode(_ axis: DimensionAxis) -> String {
        switch dimension(axis) {
        case .current: "current"
        case .points: "points"
        case .fraction: "fraction"
        }
    }

    private func dimensionModeBinding(_ axis: DimensionAxis) -> Binding<String> {
        Binding(
            get: { dimensionMode(axis) },
            set: { mode in
                let existing = dimension(axis)
                let replacement: WindowLayoutDimension = switch mode {
                case "current": .current
                case "points":
                    if case let .points(value) = existing { .points(value) } else { .points(800) }
                default:
                    if case let .fraction(value) = existing { .fraction(value) } else { .fraction(0.6) }
                }
                setDimension(replacement, axis: axis)
                commitDraft()
            }
        )
    }

    private func dimensionValueBinding(_ axis: DimensionAxis) -> Binding<Double> {
        Binding(
            get: {
                switch dimension(axis) {
                case .current: 60
                case let .points(value): value
                case let .fraction(value): value * 100
                }
            },
            set: { value in
                switch dimension(axis) {
                case .current:
                    break
                case .points:
                    setDimension(.points(value), axis: axis)
                case .fraction:
                    setDimension(.fraction(value / 100), axis: axis)
                }
            }
        )
    }

    private func dimensionRange(_ axis: DimensionAxis) -> ClosedRange<Double> {
        switch dimension(axis) {
        case .current, .fraction: 5...100
        case .points: 100...3_000
        }
    }

    private func dimensionValueText(_ axis: DimensionAxis) -> String {
        switch dimension(axis) {
        case .current: "—"
        case let .fraction(value): "\(Int((value * 100).rounded()))%"
        case let .points(value): "\(Int(value.rounded())) pt"
        }
    }

    private func offsetBinding(_ axis: DimensionAxis) -> Binding<Double> {
        Binding(
            get: {
                switch axis {
                case .width: draft.offsetX
                case .height: draft.offsetY
                }
            },
            set: { value in
                switch axis {
                case .width: draft.offsetX = value
                case .height: draft.offsetY = value
                }
            }
        )
    }

    private func commitDraft() {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard plugin.updateCustomCommand(draft),
              let stored = plugin.customCommand(id: commandID)
        else {
            synchronizeDraftIfNeeded()
            return
        }
        if stored != draft {
            draft = stored
        }
    }

    private func synchronizeDraftIfNeeded() {
        guard !isNameFocused,
              let current = plugin.customCommand(id: commandID),
              current != draft
        else { return }
        draft = current
    }
}

private struct WindowCustomLayoutPreview: View {
    let command: WindowCustomCommand

    var body: some View {
        GeometryReader { proxy in
            let frame = WindowCustomCommandPreviewLayout(command: command)
                .windowFrame(in: proxy.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.control,
                    style: .continuous
                )
                .fill(PluginSettingsTheme.Palette.recessedControlBackground)

                Rectangle()
                    .fill(PluginSettingsTheme.Palette.separator)
                    .frame(height: 8)

                RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.field,
                    style: .continuous
                )
                .fill(Color.accentColor.opacity(0.24))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PluginSettingsTheme.Radius.field,
                        style: .continuous
                    )
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: PluginSettingsTheme.Radius.control,
                    style: .continuous
                )
                .strokeBorder(
                    PluginSettingsTheme.Palette.cardBorder,
                    lineWidth: PluginSettingsTheme.Stroke.standard
                )
            }
            .clipShape(RoundedRectangle(
                cornerRadius: PluginSettingsTheme.Radius.control,
                style: .continuous
            ))
        }
    }
}
