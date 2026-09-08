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
    let resetZoomLabel: String
    let zoomHelpLabel: String
    let open: (StorageExplorerRow) -> Void
    let toggleReview: (StorageExplorerRow) -> Void
    @StateObject private var interaction = StorageExplorerTreemapInteraction()
    @State private var tiles: [StorageExplorerTreemapLayout.Tile] = []
    @State private var viewport = StorageExplorerTreemapViewport()
    @State private var magnificationStart: StorageExplorerTreemapViewport?
    @State private var panStart: StorageExplorerTreemapViewport?

    var body: some View {
        GeometryReader { geometry in
            let layoutKey = StorageExplorerTreemapLayoutKey(rows: rows, size: geometry.size)
            Canvas { context, _ in
                context.translateBy(x: viewport.offset.width, y: viewport.offset.height)
                context.scaleBy(x: viewport.scale, y: viewport.scale)
                for tile in tiles {
                    let rect = tile.rect.insetBy(dx: 1, dy: 1)
                    guard rect.width > 0, rect.height > 0 else { continue }
                    let path = Path(roundedRect: rect, cornerRadius: 4)
                    context.fill(path, with: .color(color(tile.row).opacity(0.88)))
                    if selection == tile.id {
                        context.stroke(path, with: .color(.primary), lineWidth: 3 / viewport.scale)
                    }
                    if basket.contains(tile.id) {
                        context.stroke(path, with: .color(Color.accentColor), lineWidth: 4 / viewport.scale)
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
            // The adjacent native table exposes the same rows with full accessibility actions.
            .accessibilityHidden(true)
            .overlay {
                if tiles.isEmpty { Text(emptyLabel).foregroundStyle(.secondary) }
            }
            .overlay {
                if let tile = hoveredTile {
                    let rect = viewport.transformed(tile.rect).insetBy(dx: 1, dy: 1)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: max(0, rect.width), height: max(0, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
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
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if viewport.isZoomed {
                    Button(resetZoomLabel) {
                        viewport.reset()
                        interaction.clearHover()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(zoomHelpLabel)
                    .padding(8)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    interaction.update(pointer: point, hoveredID: tile(at: point, viewport: viewport)?.id)
                case .ended:
                    interaction.clearHover()
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { event in
                if let tile = tile(at: event.location, viewport: viewport), tile.id != "group:other" {
                    open(tile.row)
                }
            }.exclusively(before: SpatialTapGesture().onEnded { event in
                if let tile = tile(at: event.location, viewport: viewport), tile.id != "group:other" {
                    selection = tile.id
                }
            }))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { magnification in
                        if magnificationStart == nil { magnificationStart = viewport }
                        guard var next = magnificationStart else { return }
                        let anchor = interaction.pointer
                            ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        next.zoom(to: next.scale * magnification, around: anchor, in: geometry.size)
                        viewport = next
                        interaction.update(pointer: anchor, hoveredID: tile(at: anchor, viewport: next)?.id)
                    }
                    .onEnded { _ in magnificationStart = nil }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard viewport.isZoomed || panStart != nil else { return }
                        if panStart == nil { panStart = viewport }
                        guard var next = panStart else { return }
                        next.pan(by: value.translation, in: geometry.size)
                        viewport = next
                        interaction.clearHover()
                    }
                    .onEnded { _ in panStart = nil }
            )
            .background {
                StorageExplorerScrollWheelMonitor { delta, precise, location in
                    let sensitivity: CGFloat = precise ? 0.012 : 0.09
                    let factor = exp(min(max(delta * sensitivity, -0.35), 0.35))
                    var next = viewport
                    next.zoom(by: factor, around: location, in: geometry.size)
                    viewport = next
                    interaction.update(pointer: location, hoveredID: tile(at: location, viewport: next)?.id)
                }
            }
            .contextMenu {
                if let row = hoveredTile?.row {
                    Button(basket.contains(row.id) ? removeReviewLabel : addReviewLabel) {
                        toggleReview(row)
                    }
                }
            }
            .help(zoomHelpLabel)
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

    private func tile(
        at point: CGPoint,
        viewport: StorageExplorerTreemapViewport
    ) -> StorageExplorerTreemapLayout.Tile? {
        let contentPoint = viewport.contentPoint(for: point)
        return tiles.first { $0.rect.contains(contentPoint) }
    }

    private func updateLayout(size: CGSize) {
        tiles = StorageExplorerTreemapLayout.tiles(
            rows: rows,
            in: CGRect(origin: .zero, size: size)
        )
        viewport.reset()
        interaction.clearHover()
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

struct StorageExplorerTreemapViewport: Equatable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 8

    var scale: CGFloat = 1
    var offset: CGSize = .zero

    var isZoomed: Bool { scale > Self.minimumScale + 0.001 }

    mutating func zoom(by factor: CGFloat, around anchor: CGPoint, in size: CGSize) {
        zoom(to: scale * factor, around: anchor, in: size)
    }

    mutating func zoom(to requestedScale: CGFloat, around anchor: CGPoint, in size: CGSize) {
        let resolvedScale = min(max(requestedScale, Self.minimumScale), Self.maximumScale)
        guard resolvedScale != scale else { return }
        let ratio = resolvedScale / scale
        offset = CGSize(
            width: anchor.x - ((anchor.x - offset.width) * ratio),
            height: anchor.y - ((anchor.y - offset.height) * ratio)
        )
        scale = resolvedScale
        clampOffset(in: size)
    }

    mutating func pan(by translation: CGSize, in size: CGSize) {
        offset.width += translation.width
        offset.height += translation.height
        clampOffset(in: size)
    }

    mutating func reset() {
        scale = Self.minimumScale
        offset = .zero
    }

    func contentPoint(for point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - offset.width) / scale,
            y: (point.y - offset.height) / scale
        )
    }

    func transformed(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * scale + offset.width,
            y: rect.minY * scale + offset.height,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private mutating func clampOffset(in size: CGSize) {
        guard isZoomed else {
            offset = .zero
            return
        }
        offset.width = min(0, max(size.width - size.width * scale, offset.width))
        offset.height = min(0, max(size.height - size.height * scale, offset.height))
    }
}

@MainActor
private final class StorageExplorerTreemapInteraction: ObservableObject {
    @Published private(set) var hoveredID: String?
    private(set) var pointer: CGPoint?

    func update(pointer: CGPoint, hoveredID: String?) {
        self.pointer = pointer
        if self.hoveredID != hoveredID { self.hoveredID = hoveredID }
    }

    func clearHover() {
        pointer = nil
        if hoveredID != nil { hoveredID = nil }
    }
}

private struct StorageExplorerScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (CGFloat, Bool, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = StorageExplorerScrollCaptureView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onScroll: (CGFloat, Bool, CGPoint) -> Void
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat, Bool, CGPoint) -> Void) {
            self.onScroll = onScroll
        }

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let view = self.view,
                      event.window === view.window
                else {
                    return event
                }
                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }
                self.onScroll(event.scrollingDeltaY, event.hasPreciseScrollingDeltas, location)
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            view = nil
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private final class StorageExplorerScrollCaptureView: NSView {
    override var isFlipped: Bool { true }
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
