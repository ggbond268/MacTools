import AppKit
import MacToolsPluginKit

/// Offsets use SwiftUI's move semantics: an insertion boundary in the original sequence.
enum PanelLayoutDestination {
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 8

    static func listOffset(at point: CGPoint, count: Int) -> Int {
        min(max(Int(floor((point.y + rowSpacing / 2) / (rowHeight + rowSpacing) + 0.5)), 0), count)
    }

    static func gridOffset(at point: CGPoint, placements: [ComponentGridPlacement], rightToLeft: Bool) -> Int {
        guard !placements.isEmpty else { return 0 }
        if point.y < 0 { return 0 }
        if point.y >= ComponentPanelLayout.gridContentHeight(for: placements) { return placements.count }
        let logicalPoint = CGPoint(
            x: rightToLeft ? ComponentPanelLayout.gridWidth - point.x : point.x,
            y: point.y
        )
        // Use the committed layout as the hit map throughout the drag. Hit-testing the
        // repacked preview would make a stationary pointer repeatedly move its own target.
        let nearest = placements.enumerated().min { lhs, rhs in
            distance(logicalPoint, to: frame(lhs.element)) < distance(logicalPoint, to: frame(rhs.element))
        }!
        let rect = frame(nearest.element)
        return nearest.offset + (logicalPoint.x >= rect.midX ? 1 : 0)
    }

    static func frame(_ placement: ComponentGridPlacement) -> CGRect {
        CGRect(
            x: ComponentPanelLayout.xOffset(for: placement), y: placement.yOffset,
            width: ComponentPanelLayout.itemWidth(for: placement.span),
            height: ComponentPanelLayout.itemHeight(for: placement.span)
        )
    }

    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    static func moving(_ id: String, toOffset offset: Int, in ids: [String]) -> [String] {
        guard let source = ids.firstIndex(of: id) else { return ids }
        let boundary = min(max(offset, 0), ids.count)
        var result = ids
        result.remove(at: source)
        result.insert(id, at: boundary > source ? boundary - 1 : boundary)
        return result
    }

    static func scrollDelta(pointerY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, pointerY >= 0, pointerY <= viewportHeight else { return 0 }
        let edge = min(36, viewportHeight / 3)
        if pointerY < edge { return -12 * (1 - pointerY / edge) }
        if pointerY > viewportHeight - edge { return 12 * (1 - (viewportHeight - pointerY) / edge) }
        return 0
    }
}

@MainActor
final class PanelLayoutEditingSession: ObservableObject {
    struct Move: Equatable {
        let id: String
        let offset: Int
    }

    @Published private(set) var sourceID: String?
    @Published private(set) var destination: Int?
    private(set) var originalIDs: [String] = []
    private(set) var token: String?

    func begin(id: String, ids: [String]) -> String? {
        cancel()
        guard ids.count >= 2, ids.contains(id) else { return nil }
        originalIDs = ids
        sourceID = id
        token = UUID().uuidString
        return token
    }

    func validate(ids: [String]) -> Bool {
        guard sourceID != nil, ids == originalIDs else {
            cancel()
            return false
        }
        return true
    }

    func preview(offset: Int, ids: [String]) {
        guard validate(ids: ids) else { return }
        destination = min(max(offset, 0), ids.count)
    }

    func previewIDs(currentIDs: [String]) -> [String] {
        guard currentIDs == originalIDs, let sourceID, let destination else { return currentIDs }
        return PanelLayoutDestination.moving(sourceID, toOffset: destination, in: currentIDs)
    }

    func leave() { destination = nil }

    func finish(ids: [String]) -> Move? {
        defer { cancel() }
        guard validate(ids: ids), let sourceID, let destination,
              previewIDs(currentIDs: ids) != ids else { return nil }
        return Move(id: sourceID, offset: destination)
    }

    func cancel() {
        destination = nil
        sourceID = nil
        originalIDs = []
        token = nil
    }
}

enum PanelLayoutCopy {
    static var edit: String { text("edit", "编辑布局") }
    static var done: String { text("done", "完成") }
    static var earlier: String { text("earlier", "向前移动") }
    static var later: String { text("later", "向后移动") }
    static var beginning: String { text("beginning", "移到开头") }
    static var end: String { text("end", "移到末尾") }
    static var hint: String { text("hint", "拖移排序，或使用移动菜单。") }
    static func position(_ title: String, index: Int, count: Int) -> String {
        AppL10n.settingsFormat("panel.layout.position", defaultValue: "%@，第 %lld 项，共 %lld 项", title, index + 1, count)
    }
    private static func text(_ key: String, _ fallback: String) -> String {
        AppL10n.settings("panel.layout.\(key)", defaultValue: fallback)
    }
}
