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
    let navigateUp: () -> Void
    let toggleReview: (StorageExplorerRow) -> Void
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geometry in
            let tiles = StorageExplorerTreemapLayout.tiles(rows: rows, in: CGRect(origin: .zero, size: geometry.size))
            Canvas { context, _ in
                for tile in tiles {
                    let rect = tile.rect.insetBy(dx: 1, dy: 1)
                    guard rect.width > 0, rect.height > 0 else { continue }
                    let path = Path(roundedRect: rect, cornerRadius: 4)
                    context.fill(path, with: .color(color(tile.row).opacity(hovered == tile.id ? 1 : 0.85)))
                    if selection == tile.id { context.stroke(path, with: .color(.primary), lineWidth: 3) }
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
                        let label = Text(name).font(.system(.caption, weight: .semibold)).foregroundStyle(.white)
                        var resolved = context.resolve(label)
                        resolved.shading = .color(.white)
                        context.draw(resolved, in: CGRect(x: rect.minX + 8, y: rect.minY + 6, width: rect.width - 16, height: 18))
                        if rect.height > 55 {
                            context.draw(Text(tile.row.sizeLabel).font(.caption2).foregroundStyle(.white),
                                in: CGRect(x: rect.minX + 8, y: rect.minY + 26, width: rect.width - 16, height: 16))
                        }
                    }
                }
            }
            .overlay {
                if tiles.isEmpty { Text(emptyLabel).foregroundStyle(.secondary) }
            }
            .overlay(alignment: .topTrailing) {
                if let row = rows.first(where: { $0.id == hovered }) {
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
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = tiles.first { $0.rect.contains(point) }?.id
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { event in
                if let tile = tiles.first(where: { $0.rect.contains(event.location) }), tile.id != "group:other" { open(tile.row) }
            }.exclusively(before: SpatialTapGesture().onEnded { event in
                if let tile = tiles.first(where: { $0.rect.contains(event.location) }), tile.id != "group:other" { selection = tile.id }
            }))
            .simultaneousGesture(
                MagnificationGesture().onEnded { scale in
                    if scale > 1.12,
                       let hovered,
                       let row = rows.first(where: { $0.id == hovered }),
                       row.item.isDirectory,
                       !row.item.isPackage {
                        open(row)
                    } else if scale < 0.88 {
                        navigateUp()
                    }
                }
            )
            .contextMenu {
                if let hovered,
                   let row = rows.first(where: { $0.id == hovered }) {
                    Button(basket.contains(row.id) ? removeReviewLabel : addReviewLabel) {
                        toggleReview(row)
                    }
                }
            }
            // The linked native table supplies keyboard selection and VoiceOver semantics for every item.
            .accessibilityHidden(true)
        }
    }

    private func color(_ row: StorageExplorerRow) -> Color {
        let palette: [Color] = [.blue, .teal, .indigo, .purple, .orange, .pink, .green]
        let key = row.item.isDirectory ? row.id : row.kind
        let hash = key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
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
