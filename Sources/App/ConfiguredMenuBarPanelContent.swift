import AppKit
import MacToolsPluginKit
import SwiftUI

enum ConfiguredMenuBarPanelLayout {
    static let itemSpacing = ComponentPanelLayout.verticalSpacing

    struct Placement: Equatable {
        var components: [ComponentGridPlacement] = []
        var featureOffsets: [String: CGFloat] = [:]
        var featureHeights: [String: CGFloat] = [:]
        var height: CGFloat = 0
    }

    static func componentHeight(_ items: [PluginComponentItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return ComponentPanelLayout.gridContentHeight(for: ComponentGridPlacementEngine.placements(for: items))
    }

    static func placement(
        entries: [MenuBarPanelEntry], components: [PluginComponentItem], features: [PluginPanelItem]
    ) -> Placement {
        let componentLookup = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        let featureLookup = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        var result = Placement()
        var pendingComponents: [(id: String, span: PluginComponentSpan)] = []
        var previousSurface: PluginDisplaySurface?

        func flushComponents() {
            guard !pendingComponents.isEmpty else { return }
            if previousSurface != nil { result.height += itemSpacing }
            let placements = ComponentGridPlacementEngine.placements(for: pendingComponents)
            let originY = result.height
            result.components += placements.map {
                ComponentGridPlacement(id: $0.id, row: $0.row, column: $0.column, span: $0.span,
                                       yOffset: originY + $0.yOffset)
            }
            result.height += ComponentPanelLayout.gridContentHeight(for: placements)
            pendingComponents.removeAll(keepingCapacity: true)
            previousSurface = .dashboard
        }

        for entry in entries {
            switch entry.surface {
            case .dashboard:
                if let item = componentLookup[entry.pluginID] { pendingComponents.append((entry.presentationID, item.span)) }
            case .featurePanel:
                guard let item = featureLookup[entry.pluginID] else { continue }
                // A full-width action ends the current card grid; later cards cannot fill earlier gaps.
                flushComponents()
                if let previousSurface {
                    result.height += previousSurface == .featurePanel ? MenuBarPanelLayout.featureRowSpacing : itemSpacing
                }
                result.featureOffsets[entry.presentationID] = result.height
                let height = MenuBarPanelLayout.rowHeight(for: item)
                result.featureHeights[entry.presentationID] = height
                result.height += height
                previousSurface = .featurePanel
            }
        }
        flushComponents()
        return result
    }

    static func contentHeight(
        components: [PluginComponentItem], features: [PluginPanelItem], screen: NSScreen?,
        entries: [MenuBarPanelEntry]? = nil
    ) -> CGFloat {
        if entries == nil {
            if components.isEmpty { return MenuBarPanelLayout.preferredFeatureContentHeight(for: features, screen: screen) }
            if features.isEmpty { return ComponentPanelLayout.preferredContentHeight(for: components, screen: screen) }
        }
        let entries = entries ?? components.map { MenuBarPanelEntry(pluginID: $0.id, surface: .dashboard) }
            + features.map { MenuBarPanelEntry(pluginID: $0.id, surface: .featurePanel) }
        let height = placement(entries: entries, components: components, features: features).height
        if components.isEmpty {
            return MenuBarPanelLayout.preferredFeatureContentHeight(featureContentHeight: height,
                maximumFeatureListHeight: MenuBarPanelLayout.maximumFeatureListHeight(for: screen))
        }
        let raw = height + MenuBarPanelLayout.contentVerticalPadding
        let minimum = features.isEmpty ? raw : MenuBarPanelLayout.minimumContentHeight
        return min(max(raw, minimum), MenuBarPanelLayout.maximumContentHeight(for: screen))
    }
}

struct ConfiguredMenuBarPanelsContent: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var model: MenuBarUnifiedPanelModel
    let contentBodyHeight: CGFloat
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void
    @State private var visited: Set<String> = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pluginHost.menuBarPanels.filter { visited.contains($0.id) || $0.id == model.selectedTab.id }) {
                panel in
                ConfiguredMenuBarPanelContent(
                    pluginHost: pluginHost, panelID: panel.id,
                    availableBodyHeight: contentBodyHeight,
                    maximumFeatureListHeight: model.maximumFeatureListHeight,
                    isVisible: model.isPanelVisible && panel.id == model.selectedTab.id,
                    onDismiss: onDismiss, onOpenSettings: onOpenSettings,
                    onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
                    onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration
                )
                .opacity(panel.id == model.selectedTab.id ? 1 : 0)
                .allowsHitTesting(model.isPanelVisible && panel.id == model.selectedTab.id)
                .accessibilityHidden(panel.id != model.selectedTab.id)
            }
        }
        .onAppear { visited.insert(model.selectedTab.id) }
        .onChange(of: model.selectedTab) { old, new in
            visited.insert(old.id)
            visited.insert(new.id)
        }
        .onChange(of: pluginHost.menuBarPanels.map(\.id)) { _, ids in visited.formIntersection(ids) }
    }
}

private struct ConfiguredMenuBarPanelContent: View {
    @ObservedObject var pluginHost: PluginHost
    let panelID: String
    let availableBodyHeight: CGFloat
    let maximumFeatureListHeight: CGFloat
    let isVisible: Bool
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void

    @State private var retainedBodyHeight: CGFloat?
    @State private var isComponentDetailInline = false
    @State private var isFeatureDetailInline = false
    private var contentBodyHeight: CGFloat {
        isVisible ? availableBodyHeight : (retainedBodyHeight ?? availableBodyHeight)
    }

    var body: some View {
        let components = pluginHost.componentItems(in: panelID)
        let features = pluginHost.panelItems(in: panelID)
        let mixed = !components.isEmpty && !features.isEmpty
        Group {
            if mixed {
                let placement = ConfiguredMenuBarPanelLayout.placement(
                    entries: pluginHost.panelEntries(in: panelID), components: components, features: features
                )
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        componentContent(components, height: placement.height, embedded: true,
                                         placements: placement.components)
                            .opacity(isFeatureDetailInline ? 0 : 1)
                            .allowsHitTesting(!isFeatureDetailInline)
                        featureContent(features, height: placement.height, embedded: true,
                                       rowOffsets: placement.featureOffsets)
                            .opacity(isComponentDetailInline ? 0 : 1)
                            .allowsHitTesting(!isComponentDetailInline)
                    }
                    .frame(width: MenuBarPanelLayout.surfaceWidth, height: placement.height, alignment: .topLeading)
                }
                .background(ScrollViewScrollerVisibilityConfigurator())
            } else if !components.isEmpty {
                let placement = ConfiguredMenuBarPanelLayout.placement(
                    entries: pluginHost.panelEntries(in: panelID), components: components, features: []
                )
                componentContent(components, height: contentBodyHeight, placements: placement.components,
                                 gridHeight: placement.height)
            } else if !features.isEmpty {
                featureContent(features, height: contentBodyHeight)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(FeatureL10n.string("此面板暂无内容"))
                        .font(.subheadline)
                    Text(FeatureL10n.string("在编辑面板中添加内容"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: MenuBarPanelLayout.surfaceWidth, height: contentBodyHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: ComponentPanelLayout.scrollClipCornerRadius, style: .continuous))
        .onAppear { if isVisible { retainedBodyHeight = availableBodyHeight } }
        .onChange(of: isVisible) { _, visible in if visible { retainedBodyHeight = availableBodyHeight } }
        .onChange(of: availableBodyHeight) { _, height in if isVisible { retainedBodyHeight = height } }
    }

    private func componentContent(
        _ items: [PluginComponentItem], height: CGFloat, embedded: Bool = false,
        placements: [ComponentGridPlacement]? = nil, gridHeight: CGFloat? = nil
    ) -> some View {
        ComponentPanelContent(
            pluginHost: pluginHost, contentBodyHeight: height, isPanelVisible: isVisible,
            onDismiss: onDismiss, panelID: panelID, suppliedItems: items,
            suppliedEntries: pluginHost.panelEntries(in: panelID).filter { $0.surface == .dashboard }, embedded: embedded,
            suppliedPlacements: placements, suppliedGridHeight: gridHeight ?? (placements == nil ? nil : height),
            onInlinePresentationChange: { isComponentDetailInline = $0 }
        )
    }

    private func featureContent(
        _ items: [PluginPanelItem], height: CGFloat, embedded: Bool = false,
        rowOffsets: [String: CGFloat]? = nil
    ) -> some View {
        MenuBarContent(
            pluginHost: pluginHost, contentBodyHeight: height,
            maximumFeatureListHeight: embedded ? height : maximumFeatureListHeight,
            isPanelVisible: isVisible, onDismiss: onDismiss, onOpenSettings: onOpenSettings,
            onPresentDiskCleanConfiguration: onPresentDiskCleanConfiguration,
            onPresentLaunchControlConfiguration: onPresentLaunchControlConfiguration,
            suppliedItems: items, suppliedEntries: pluginHost.panelEntries(in: panelID).filter { $0.surface == .featurePanel },
            embedded: embedded, suppliedRowOffsets: rowOffsets,
            onInlinePresentationChange: { isFeatureDetailInline = $0 }
        )
    }
}
