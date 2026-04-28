import AppKit
import SwiftUI

struct ComponentGridPlacement: Identifiable, Equatable {
    let id: String
    let row: Int
    let column: Int
    let span: PluginComponentSpan
}

enum ComponentPanelLayout {
    static let columns = 4
    static let cellWidth: CGFloat = 75
    static let cellHeight: CGFloat = 104
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 0
    static let verticalPadding: CGFloat = 10
    static let emptyContentHeight: CGFloat = 164
    static let maximumPanelHeight: CGFloat = 720
    static let minimumPanelHeight: CGFloat = 220

    static var gridWidth: CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(columns - 1) * spacing
    }

    static var panelWidth: CGFloat {
        gridWidth + horizontalPadding * 2
    }

    static var contentVerticalPadding: CGFloat {
        verticalPadding * 2
    }

    static func itemWidth(for span: PluginComponentSpan) -> CGFloat {
        CGFloat(span.width) * cellWidth + CGFloat(span.width - 1) * spacing
    }

    static func itemHeight(for span: PluginComponentSpan) -> CGFloat {
        CGFloat(span.height) * cellHeight + CGFloat(span.height - 1) * spacing
    }

    static func xOffset(for placement: ComponentGridPlacement) -> CGFloat {
        CGFloat(placement.column) * (cellWidth + spacing)
    }

    static func yOffset(for placement: ComponentGridPlacement) -> CGFloat {
        CGFloat(placement.row) * (cellHeight + spacing)
    }

    static func gridContentHeight(for placements: [ComponentGridPlacement]) -> CGFloat {
        guard let maximumRow = placements.map({ $0.row + $0.span.height }).max() else {
            return emptyContentHeight
        }

        return CGFloat(maximumRow) * cellHeight + CGFloat(max(maximumRow - 1, 0)) * spacing
    }

    static func preferredPanelHeight(for items: [PluginComponentItem], screen: NSScreen?) -> CGFloat {
        let rawContentHeight: CGFloat

        if items.isEmpty {
            rawContentHeight = emptyContentHeight
        } else {
            let placements = ComponentGridPlacementEngine.placements(for: items, columns: columns)
            rawContentHeight = gridContentHeight(for: placements)
        }

        let contentHeight = rawContentHeight + contentVerticalPadding
        let screenMaximum = (screen?.visibleFrame.height ?? maximumPanelHeight) - 48
        let maximumHeight = max(minimumPanelHeight, min(maximumPanelHeight, screenMaximum))
        let minimumHeight = items.isEmpty ? minimumPanelHeight : contentHeight
        return min(max(contentHeight, minimumHeight), maximumHeight)
    }
}

enum ComponentGridPlacementEngine {
    static func placements(
        for items: [PluginComponentItem],
        columns: Int = ComponentPanelLayout.columns
    ) -> [ComponentGridPlacement] {
        var occupiedCells: Set<GridCell> = []
        var placements: [ComponentGridPlacement] = []

        for item in items {
            let span = item.span
            var row = 0

            while true {
                var didPlace = false

                for column in 0..<columns where canPlace(
                    span: span,
                    row: row,
                    column: column,
                    columns: columns,
                    occupiedCells: occupiedCells
                ) {
                    placements.append(
                        ComponentGridPlacement(
                            id: item.id,
                            row: row,
                            column: column,
                            span: span
                        )
                    )
                    markOccupied(
                        span: span,
                        row: row,
                        column: column,
                        occupiedCells: &occupiedCells
                    )
                    didPlace = true
                    break
                }

                if didPlace {
                    break
                }

                row += 1
            }
        }

        return placements
    }

    private static func canPlace(
        span: PluginComponentSpan,
        row: Int,
        column: Int,
        columns: Int,
        occupiedCells: Set<GridCell>
    ) -> Bool {
        guard column + span.width <= columns else {
            return false
        }

        for occupiedRow in row..<(row + span.height) {
            for occupiedColumn in column..<(column + span.width) {
                if occupiedCells.contains(GridCell(row: occupiedRow, column: occupiedColumn)) {
                    return false
                }
            }
        }

        return true
    }

    private static func markOccupied(
        span: PluginComponentSpan,
        row: Int,
        column: Int,
        occupiedCells: inout Set<GridCell>
    ) {
        for occupiedRow in row..<(row + span.height) {
            for occupiedColumn in column..<(column + span.width) {
                occupiedCells.insert(GridCell(row: occupiedRow, column: occupiedColumn))
            }
        }
    }

    private struct GridCell: Hashable {
        let row: Int
        let column: Int
    }
}

struct ComponentPanelContent: View {
    @ObservedObject var pluginHost: PluginHost
    let panelHeight: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if pluginHost.componentItems.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    ComponentGridView(
                        pluginHost: pluginHost,
                        items: pluginHost.componentItems,
                        onDismiss: onDismiss
                    )
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, ComponentPanelLayout.horizontalPadding)
        .padding(.vertical, ComponentPanelLayout.verticalPadding)
        .frame(width: ComponentPanelLayout.panelWidth, height: panelHeight, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text("暂无组件")
                    .font(.system(size: 14, weight: .semibold))

                Text("启用组件后会显示在这里。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: ComponentPanelLayout.emptyContentHeight)
        .frame(maxWidth: .infinity)
    }
}

private struct ComponentGridView: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [PluginComponentItem]
    let onDismiss: () -> Void

    private var placements: [ComponentGridPlacement] {
        ComponentGridPlacementEngine.placements(for: items)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placements) { placement in
                if let item = items.first(where: { $0.id == placement.id }) {
                    ComponentCardContainer(
                        pluginHost: pluginHost,
                        item: item,
                        onDismiss: onDismiss
                    )
                    .frame(
                        width: ComponentPanelLayout.itemWidth(for: placement.span),
                        height: ComponentPanelLayout.itemHeight(for: placement.span)
                    )
                    .offset(
                        x: ComponentPanelLayout.xOffset(for: placement),
                        y: ComponentPanelLayout.yOffset(for: placement)
                    )
                }
            }
        }
        .frame(
            width: ComponentPanelLayout.gridWidth,
            height: ComponentPanelLayout.gridContentHeight(for: placements),
            alignment: .topLeading
        )
    }
}

private struct ComponentCardContainer: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginComponentItem
    let onDismiss: () -> Void

    var body: some View {
        pluginHost.makeComponentView(for: item.id, dismiss: onDismiss)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .disabled(!item.isEnabled)
            .opacity(item.isEnabled ? 1 : 0.55)
            .help(item.helpText)
    }
}
