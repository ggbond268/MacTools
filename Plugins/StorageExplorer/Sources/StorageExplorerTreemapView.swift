import AppKit
import Quartz
import SwiftUI

struct StorageExplorerTreemapView: View {
    let rows: [StorageExplorerRow]
    @Binding var selection: String?
    let basket: Set<String>
    let otherLabel: String
    let emptyLabel: String
    let addReviewLabel: String
    let removeReviewLabel: String
    let open: (StorageExplorerRow) -> Void
    let toggleReview: (StorageExplorerRow) -> Void
    @StateObject private var interaction = StorageExplorerTreemapInteraction()
    @State private var tiles: [StorageExplorerTreemapLayout.Tile] = []

    var body: some View {
        GeometryReader { geometry in
            let layoutKey = StorageExplorerTreemapLayoutKey(rows: rows, size: geometry.size)
            StorageExplorerTreemapCanvas(
                tiles: tiles,
                basket: basket,
                otherLabel: otherLabel
            )
            .equatable()
            // The adjacent native table exposes the same rows with full accessibility actions.
            .accessibilityHidden(true)
            .overlay {
                if tiles.isEmpty { Text(emptyLabel).foregroundStyle(.secondary) }
            }
            .overlay {
                if let tile = selectedTile {
                    let rect = tile.rect.insetBy(dx: 1.5, dy: 1.5)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary, lineWidth: 3)
                        .frame(width: max(0, rect.width), height: max(0, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let tile = hoveredTile {
                    let rect = tile.rect.insetBy(dx: 1, dy: 1)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: max(0, rect.width), height: max(0, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.14), value: selection)
            .overlay(alignment: .topTrailing) {
                if let row = hoveredTile?.row {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text("\(row.sizeLabel) · \(row.percentage)")
                            .font(.caption2).monospacedDigit()
                        Text(row.item.path).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                }
            }
            .animation(.easeOut(duration: 0.1), value: interaction.hoveredID)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    interaction.update(hoveredID: tile(at: point)?.id)
                case .ended:
                    interaction.clearHover()
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { event in
                if let tile = tile(at: event.location), tile.id != "group:other" {
                    open(tile.row)
                }
            }.exclusively(before: SpatialTapGesture().onEnded { event in
                if let tile = tile(at: event.location), tile.id != "group:other" {
                    selection = tile.id
                }
            }))
            .contextMenu {
                if let row = hoveredTile?.row {
                    Button(basket.contains(row.id) ? removeReviewLabel : addReviewLabel) {
                        toggleReview(row)
                    }
                }
            }
            .onAppear {
                updateLayout(size: geometry.size)
            }
            .onChange(of: layoutKey) { _, _ in
                updateLayout(size: geometry.size)
            }
        }
    }

    private var hoveredTile: StorageExplorerTreemapLayout.Tile? {
        guard let hoveredID = interaction.hoveredID else { return nil }
        return tiles.first { $0.id == hoveredID }
    }

    private var selectedTile: StorageExplorerTreemapLayout.Tile? {
        guard let selection else { return nil }
        return tiles.first { $0.id == selection }
    }

    private func tile(at point: CGPoint) -> StorageExplorerTreemapLayout.Tile? {
        tiles.first { $0.rect.contains(point) }
    }

    private func updateLayout(size: CGSize) {
        tiles = StorageExplorerTreemapLayout.tiles(
            rows: rows,
            in: CGRect(origin: .zero, size: size)
        )
        interaction.clearHover()
    }

}

private struct StorageExplorerTreemapCanvas: View, Equatable {
    let tiles: [StorageExplorerTreemapLayout.Tile]
    let basket: Set<String>
    let otherLabel: String

    var body: some View {
        Canvas { context, _ in
            for tile in tiles {
                let rect = tile.rect.insetBy(dx: 1, dy: 1)
                guard rect.width > 0, rect.height > 0 else { continue }
                let path = Path(roundedRect: rect, cornerRadius: 4)
                context.fill(path, with: .color(color(tile.row).opacity(0.88)))
                if basket.contains(tile.id) {
                    context.stroke(path, with: .color(Color.accentColor), lineWidth: 4)
                    if rect.width > 28 && rect.height > 28 {
                        context.draw(
                            Text(Image(systemName: "checkmark.circle.fill"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white),
                            at: CGPoint(x: rect.maxX - 14, y: rect.minY + 14)
                        )
                    }
                }
                if rect.width > 65 && rect.height > 35 {
                    let name = tile.id == "group:other" ? otherLabel : tile.row.name
                    let label = Text(name)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.white)
                    var resolved = context.resolve(label)
                    resolved.shading = .color(.white)
                    context.draw(
                        resolved,
                        in: CGRect(
                            x: rect.minX + 8,
                            y: rect.minY + 6,
                            width: rect.width - 16,
                            height: 18
                        )
                    )
                    if rect.height > 55 {
                        context.draw(
                            Text(tile.row.sizeLabel).font(.caption2).foregroundStyle(.white),
                            in: CGRect(
                                x: rect.minX + 8,
                                y: rect.minY + 26,
                                width: rect.width - 16,
                                height: 16
                            )
                        )
                    }
                }
            }
        }
    }

    private func color(_ row: StorageExplorerRow) -> Color {
        let palette: [Color] = [.blue, .teal, .indigo, .purple, .orange, .pink, .green]
        let key = row.item.isDirectory ? row.id : row.kind
        let hash = key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private struct StorageExplorerTreemapLayoutKey: Equatable {
    struct Entry: Equatable {
        let id: String
        let bytes: Int64
        let name: String
        let sizeLabel: String
        let percentage: String
        let kind: String
    }

    let size: CGSize
    let entries: [Entry]

    init(rows: [StorageExplorerRow], size: CGSize) {
        self.size = size
        entries = rows.map {
            Entry(
                id: $0.id,
                bytes: $0.bytes,
                name: $0.name,
                sizeLabel: $0.sizeLabel,
                percentage: $0.percentage,
                kind: $0.kind
            )
        }
    }
}

@MainActor
private final class StorageExplorerTreemapInteraction: ObservableObject {
    @Published private(set) var hoveredID: String?

    func update(hoveredID: String?) {
        if self.hoveredID != hoveredID { self.hoveredID = hoveredID }
    }

    func clearHover() {
        if hoveredID != nil { hoveredID = nil }
    }
}

struct StorageExplorerQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
