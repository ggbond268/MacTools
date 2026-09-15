import AppKit
import MacToolsPluginKit
import SwiftUI

struct PanelComponentLibraryItem: Identifiable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let component: PluginComponentItem?
    let feature: PluginPanelItem?

    @MainActor
    static func catalog(in host: PluginHost, matching query: String = "") -> [Self] {
        let components = Dictionary(uniqueKeysWithValues: host.availableComponentItems.map { ($0.id, $0) })
        let features = Dictionary(uniqueKeysWithValues: host.availablePanelItems.map { ($0.id, $0) })
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.featureManagementItems.compactMap { item in
            guard components[item.id] != nil || features[item.id] != nil,
                  query.isEmpty || [item.title, item.description].contains(where: {
                      $0.localizedStandardContains(query)
                  }) else { return nil }
            return Self(id: item.id, title: item.title, description: item.description,
                        iconName: item.iconName, iconTint: item.iconTint,
                        component: components[item.id], feature: features[item.id])
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

private enum PanelComponentLibraryPreviewItem: Identifiable {
    case component(PluginComponentItem)
    case feature(PluginPanelItem)

    var entry: MenuBarPanelEntry {
        switch self {
        case .component(let item): .init(pluginID: item.id, surface: .dashboard)
        case .feature(let item): .init(pluginID: item.id, surface: .featurePanel)
        }
    }

    var id: String { entry.templateID }

    var sourceSize: CGSize {
        switch self {
        case .component(let item):
            CGSize(width: ComponentPanelLayout.itemWidth(for: item.span), height: ComponentPanelLayout.itemHeight(for: item.span))
        case .feature(let item):
            CGSize(width: ComponentPanelLayout.gridWidth, height: MenuBarPanelLayout.rowHeight(for: item))
        }
    }

    var title: String {
        FeatureL10n.string(entry.surface == .dashboard ? "卡片" : "功能行")
    }
}

/// Use known panel dimensions to place previews in one pass, without mounting views for measurement.
enum PanelComponentLibraryLayout {
    static let spacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 20

    static func columnWidth(availableWidth: CGFloat) -> CGFloat {
        max(0, (availableWidth - spacing) / 2)
    }

    static func previewSize(_ source: CGSize, columnWidth: CGFloat) -> CGSize {
        let scale = columnWidth / ComponentPanelLayout.gridWidth
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    static func columns(for sizes: [CGSize], columnWidth: CGFloat) -> [[Int]] {
        var columns = [[Int](), [Int]()]
        var heights: [CGFloat] = [0, 0]
        for (index, size) in sizes.enumerated() {
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(index)
            heights[column] += previewSize(size, columnWidth: columnWidth).height + spacing
        }
        return columns
    }
}

/// Only the selected plugin mounts previews; browsing never enables a panel or invokes a control.
struct PanelComponentLibrary: View {
    @ObservedObject var pluginHost: PluginHost
    let panelID: String
    let onAdd: (MenuBarPanelEntry) -> Bool
    @State private var query = ""
    @State private var selection: String?
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = PanelComponentLibraryItem.catalog(in: pluginHost, matching: query)
        let selected = items.first { $0.id == selection } ?? items.first
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(FeatureL10n.string("搜索组件"), text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("panel.library.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(FeatureL10n.string("清除搜索"))
                    }
                }
                .padding(7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding([.top, .horizontal], 12)

                List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                    ForEach(items) { item in
                        HStack(spacing: 9) {
                            Image(systemName: PluginSystemImage.resolvedName(item.iconName))
                                .font(.system(size: 17)).foregroundStyle(item.iconTint)
                                .frame(width: 23, height: 28)
                            Text(item.title).lineLimit(1)
                        }
                        .tag(item.id)
                        .help(item.title)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("panel.library.list")
            }
            .frame(width: 184)
            .background(.bar)

            Divider()

            Group {
                if let selected {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(selected.title).font(.title2.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 12)
                                if let panel = pluginHost.menuBarPanels.first(where: { $0.id == panelID }) {
                                    Label(panel.title, systemImage: PluginSystemImage.resolvedName(panel.systemImage))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Text(FeatureL10n.string("点击预览，添加到当前面板"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(20)

                        GeometryReader { geometry in
                            let previews = [selected.component.map(PanelComponentLibraryPreviewItem.component),
                                            selected.feature.map(PanelComponentLibraryPreviewItem.feature)].compactMap { $0 }
                            let width = PanelComponentLibraryLayout.columnWidth(
                                availableWidth: geometry.size.width - PanelComponentLibraryLayout.horizontalPadding * 2)
                            let columns = PanelComponentLibraryLayout.columns(for: previews.map(\.sourceSize), columnWidth: width)
                            ScrollView {
                                HStack(alignment: .top, spacing: PanelComponentLibraryLayout.spacing) {
                                    ForEach(columns.indices, id: \.self) { column in
                                        LazyVStack(alignment: .leading, spacing: PanelComponentLibraryLayout.spacing) {
                                            ForEach(columns[column].map { previews[$0] }) { item in
                                                preview(item, columnWidth: width)
                                            }
                                        }
                                        .frame(width: width, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, PanelComponentLibraryLayout.horizontalPadding)
                                .padding(.top, 8).padding(.bottom, 20)
                            }
                        }
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                                .padding([.horizontal, .bottom], 20)
                        }
                    }
                    .id(selected.id)
                } else if query.isEmpty {
                    ContentUnavailableView(FeatureL10n.string("暂无可添加的组件"), systemImage: "square.grid.2x2",
                        description: Text(FeatureL10n.string("支持面板的已安装插件会显示在这里。")))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("panel.library")
        .onAppear { selection = selected?.id; searchFocused = true }
        .onChange(of: items.map(\.id)) { _, ids in
            if !ids.contains(selection ?? "") { selection = ids.first }
        }
    }

    private func preview(_ item: PanelComponentLibraryPreviewItem, columnWidth: CGFloat) -> some View {
        let size = PanelComponentLibraryLayout.previewSize(item.sourceSize, columnWidth: columnWidth)
        return Button {
            errorMessage = onAdd(item.entry) ? nil : FeatureL10n.string("组件暂不可用，请稍后重试。")
        } label: {
            PanelComponentLibraryPreview(size: item.sourceSize) {
                switch item {
                case .component(let component):
                    pluginHost.componentPreviewView(for: component.id)
                case .feature(let feature):
                    AnyView(PanelComponentLibraryFeaturePreview(pluginHost: pluginHost, item: feature))
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false).accessibilityHidden(true)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelComponentLibraryPreviewButtonStyle(
            cornerRadius: MenuBarPanelLayout.cornerRadius * columnWidth / ComponentPanelLayout.gridWidth))
        .help(item.title)
        .accessibilityLabel(item.title + ", " + FeatureL10n.string("添加组件"))
        .accessibilityIdentifier("panel.library.add.\(item.id)")
    }
}

private struct PanelComponentLibraryPreviewButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PreviewLabel(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct PreviewLabel: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @State private var isHovered = false
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .clipShape(shape)
                .overlay {
                    shape.fill(Color.accentColor.opacity(configuration.isPressed ? 0.08 : (isHovered ? 0.035 : 0)))
                        .allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(borderColor, lineWidth: contrast == .increased ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }

        private var borderColor: Color {
            if isHovered || configuration.isPressed {
                return .accentColor.opacity(contrast == .increased ? 0.8 : 0.45)
            }
            return contrast == .increased ? .primary.opacity(0.35) : Color(nsColor: .separatorColor)
        }
    }
}

private struct PanelComponentLibraryPreview: View {
    let size: CGSize
    let makeContent: () -> AnyView?
    @State private var image: NSImage?
    @State private var unavailable = false
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if unavailable { Image(systemName: "square.dashed").foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard image == nil, !unavailable else { return }
            guard let content = makeContent() else { unavailable = true; return }
            // A static bitmap excludes plugin controls from keyboard focus and ongoing preview updates.
            let hosting = NSHostingView(rootView: content
                .environment(\.menuBarPanelTheme, theme)
                .environment(\.pluginComponentTheme, theme.componentTheme)
                .environment(\.colorScheme, colorScheme)
                .environment(\.locale, PluginRuntimeLocalization.locale)
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = hosting
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let result = NSImage(size: size)
                result.addRepresentation(bitmap)
                image = result
            } else {
                unavailable = true
            }
        }
    }
}

private struct PanelComponentLibraryFeaturePreview: View {
    let pluginHost: PluginHost
    let item: PluginPanelItem

    var body: some View {
        FeatureRowView(item: item,
            indicator: pluginHost.primaryPanelIndicatorsByID[item.id],
            compactIndicator: pluginHost.primaryPanelCompactIndicatorsByID[item.id],
            onDisclosureToggle: { _ in }, onSelectionChange: { _, _ in },
            onNavigationSelectionChange: { _, _ in }, onNavigationHoverChange: { _, _, _ in },
            onNavigationRowFrameChange: { _, _, _ in }, onDateChange: { _, _ in },
            onSwitchChange: { _ in false }, onSliderChange: { _, _, _ in }, onActionInvoke: { _, _ in })
    }
}
