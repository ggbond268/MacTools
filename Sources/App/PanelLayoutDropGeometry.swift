import AppKit
import MacToolsPluginKit

struct PanelLayoutDropTarget: Equatable {
    let offset: Int
    let markerFrame: CGRect?
    var isVacancy = false
}

/// The committed geometry remains the hit map until a drop is committed.
struct PanelLayoutEntryFrame: Equatable, Identifiable {
    let entry: MenuBarPanelEntry
    let frame: CGRect
    var id: String { entry.id }

    static func frames(entries: [MenuBarPanelEntry], placement: ConfiguredMenuBarPanelLayout.Placement) -> [Self] {
        let components = Dictionary(uniqueKeysWithValues: placement.components.map { ($0.id, $0) })
        return entries.compactMap { entry in
            switch entry.kind {
            case .widget:
                guard let item = components[entry.id] else { return nil }
                return Self(entry: entry, frame: PanelLayoutDestination.frame(item))
            case .row:
                guard let y = placement.featureOffsets[entry.id],
                      let height = placement.featureHeights[entry.id] else { return nil }
                return Self(entry: entry, frame: CGRect(x: 0, y: y, width: ComponentPanelLayout.gridWidth,
                                                       height: height))
            }
        }
    }
}

/// Build once with the layout snapshot. Pointer updates use allocation-free scans;
/// each occupied edge or vacant footprint supplies its own offset and marker.
struct PanelLayoutDropGeometry {
    private struct Item {
        let frame: CGRect
        let isRow: Bool
        let before: PanelLayoutDropTarget
        let after: PanelLayoutDropTarget
    }

    private let items: [Item]
    private let vacancies: [PanelLayoutDropTarget]
    private let contentHeight: CGFloat
    private let width: CGFloat

    init(frames: [PanelLayoutEntryFrame], width: CGFloat = ComponentPanelLayout.gridWidth,
         vacancies: [PanelLayoutDropTarget] = []) {
        self.width = width
        self.vacancies = vacancies
        contentHeight = frames.reduce(0) { max($0, $1.frame.maxY) }
        items = frames.enumerated().map { index, item in
            let rect = item.frame
            let isRow = item.entry.kind == .row
            let before = isRow
                ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3)
                : CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)
            let after = isRow
                ? CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3)
                : CGRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: rect.height)
            return Item(frame: rect, isRow: isRow,
                        before: .init(offset: index, markerFrame: before),
                        after: .init(offset: index + 1, markerFrame: after))
        }
    }

    func target(at physicalPoint: CGPoint, rightToLeft: Bool) -> PanelLayoutDropTarget {
        let point = CGPoint(x: rightToLeft ? width - physicalPoint.x : physicalPoint.x, y: physicalPoint.y)
        if !items.contains(where: { $0.frame.contains(point) }),
           let vacancy = vacancies.first(where: { $0.markerFrame?.contains(point) == true }) {
            return mirrored(vacancy, rightToLeft: rightToLeft)
        }
        guard let first = items.first else {
            return .init(offset: 0, markerFrame: CGRect(x: 0, y: 0, width: width, height: 3))
        }
        if point.y < 0 { return mirrored(first.before, rightToLeft: rightToLeft) }
        if point.y >= contentHeight {
            return .init(offset: items.count,
                         markerFrame: CGRect(x: 0, y: contentHeight, width: width, height: 3))
        }

        var nearest = first
        var bestDistance = CGFloat.infinity
        var hasVerticalCandidate = false
        for item in items {
            let rect = item.frame
            let sameBand = point.y >= rect.minY && point.y < rect.maxY
            // Empty space at the end of a short widget row belongs to that row,
            // not to the full-width feature immediately below it.
            if hasVerticalCandidate && !sameBand { continue }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if (sameBand && !hasVerticalCandidate) || distance < bestDistance {
                nearest = item
                bestDistance = distance
                hasVerticalCandidate = sameBand
            }
        }
        let after = nearest.isRow ? point.y >= nearest.frame.midY : point.x >= nearest.frame.midX
        return mirrored(after ? nearest.after : nearest.before, rightToLeft: rightToLeft)
    }

    private func mirrored(_ target: PanelLayoutDropTarget, rightToLeft: Bool) -> PanelLayoutDropTarget {
        guard rightToLeft, var frame = target.markerFrame else { return target }
        frame.origin.x = width - frame.maxX
        return .init(offset: target.offset, markerFrame: frame, isVacancy: target.isVacancy)
    }
}
