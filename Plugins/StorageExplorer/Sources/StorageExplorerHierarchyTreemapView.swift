import SwiftUI

struct StorageExplorerHierarchyTreemapView: View {
    let nodes: [StorageExplorerHierarchyNode]
    @Binding var selection: String?
    let emptyLabel: String
    let addReviewLabel: String
    let unavailableReviewLabel: String
    let open: (StorageItem) -> Void
    let toggleReview: (StorageItem) -> Void
    let canReview: (StorageItem) -> Bool

    @State private var hoveredID: String?
    @State private var rectangles: [StorageExplorerHierarchyRect] = []

    var body: some View {
        GeometryReader { geometry in
            let key = LayoutKey(nodes: nodes, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for entry in rectangles where entry.id != hoveredID {
                        draw(entry, context: &context)
                    }
                    if let hovered = rectangles.last(where: { $0.id == hoveredID }) {
                        draw(hovered, context: &context)
                    }
                }
                .accessibilityHidden(true)

                ForEach(rectangles) { entry in
                    interactiveRegion(entry)
                }

                if rectangles.isEmpty {
                    Text(emptyLabel)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    // Parent and child rectangles overlap by design. Resolve hover once at the
                    // container level so the deepest visible tile wins without competing events.
                    hoveredID = rectangles.last(where: { $0.rect.contains(location) })?.id
                case .ended:
                    hoveredID = nil
                }
            }
            .onAppear { updateLayout(size: geometry.size) }
            .onChange(of: key) { _, _ in updateLayout(size: geometry.size) }
        }
    }

    private func interactiveRegion(_ entry: StorageExplorerHierarchyRect) -> some View {
        let inset = entry.rect.insetBy(dx: 2, dy: 2)
        let reviewAvailable = !entry.node.isAggregate && canReview(entry.node.item)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: max(0, inset.width), height: max(0, inset.height))
            .position(x: inset.midX, y: inset.midY)
            .onTapGesture {
                guard !entry.node.isAggregate else { return }
                if entry.node.item.isDirectory && !entry.node.item.isPackage {
                    open(entry.node.item)
                } else {
                    selection = entry.id
                }
            }
            .contextMenu {
                if !entry.node.isAggregate {
                    if reviewAvailable {
                        Button(addReviewLabel) { toggleReview(entry.node.item) }
                    } else {
                        Label(unavailableReviewLabel, systemImage: "link")
                    }
                }
            }
            .modifier(StorageExplorerReviewDragModifier(
                enabled: reviewAvailable,
                item: entry.node.item,
                bytes: entry.node.bytes
            ))
            .overlay(alignment: .topTrailing) {
                if hoveredID == entry.id, reviewAvailable, inset.width > 54, inset.height > 38 {
                    Button { toggleReview(entry.node.item) } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(addReviewLabel)
                    .padding(7)
                }
            }
            .help(helpText(for: entry.node) + (entry.node.item.isSymlink ? "\n" + unavailableReviewLabel : ""))
    }

    private func draw(_ entry: StorageExplorerHierarchyRect, context: inout GraphicsContext) {
        let inset = entry.rect.insetBy(dx: entry.depth == 0 ? 1.5 : 1, dy: entry.depth == 0 ? 1.5 : 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let shape = Path(roundedRect: inset, cornerRadius: entry.depth == 0 ? 6 : 4)
        let base = color(for: entry.node.colorKey)
        let brightness = max(0.5, 0.88 - Double(entry.depth) * 0.10)
        let isHovered = hoveredID == entry.id
        let hasHover = hoveredID != nil
        context.fill(shape, with: .color(base.opacity(brightness * (hasHover && !isHovered ? 0.48 : 1))))
        if isHovered {
            context.fill(shape, with: .color(.white.opacity(0.12)))
        }
        context.stroke(
            shape,
            with: .color(isHovered ? .white : .white.opacity(entry.depth == 0 ? 0.72 : 0.42)),
            lineWidth: isHovered ? 3.5 : 1
        )
        if isHovered {
            context.stroke(shape, with: .color(.black.opacity(0.45)), lineWidth: 1)
        }
        guard inset.width > 62, inset.height > 30 else { return }
        let name = Text(entry.node.item.name)
            .font(.system(size: entry.depth == 0 ? 13 : 11, weight: .semibold))
            .foregroundStyle(.white)
        context.draw(
            name,
            in: CGRect(x: inset.minX + 8, y: inset.minY + 6, width: inset.width - 16, height: 18)
        )
        if inset.height > 52 {
            context.draw(
                Text(ByteCountFormatter.string(fromByteCount: entry.node.bytes, countStyle: .file))
                    .font(.caption2).foregroundStyle(.white.opacity(0.9)),
                in: CGRect(x: inset.minX + 8, y: inset.minY + 25, width: inset.width - 16, height: 16)
            )
        }
    }

    private func updateLayout(size: CGSize) {
        hoveredID = nil
        rectangles = StorageExplorerHierarchyRectLayout.make(
            nodes: nodes,
            in: CGRect(origin: .zero, size: size)
        )
    }

    private func color(for key: String) -> Color {
        // A muted Morandi palette keeps neighboring branches distinct without the visual
        // noise of fully saturated system colors. Rank remains meaningful: the largest
        // branches start with dusty red and progress through warm, then cool hues.
        let palette: [Color] = [
            Color(red: 0.68, green: 0.34, blue: 0.38),
            Color(red: 0.69, green: 0.46, blue: 0.37),
            Color(red: 0.64, green: 0.54, blue: 0.36),
            Color(red: 0.42, green: 0.54, blue: 0.40),
            Color(red: 0.34, green: 0.52, blue: 0.51),
            Color(red: 0.39, green: 0.48, blue: 0.61),
            Color(red: 0.48, green: 0.43, blue: 0.61),
            Color(red: 0.56, green: 0.41, blue: 0.51),
        ]
        if key.hasPrefix("size-rank:"),
           let rank = Int(key.dropFirst("size-rank:".count).prefix { $0.isNumber }) {
            return palette[min(rank, palette.count - 1)]
        }
        return .gray
    }

    private func helpText(for node: StorageExplorerHierarchyNode) -> String {
        let size = ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file)
        return node.isAggregate ? "\(node.item.name) · \(size)" : "\(node.item.name) · \(size)\n\(node.item.path)"
    }
}

private struct StorageExplorerReviewDragModifier: ViewModifier {
    let enabled: Bool
    let item: StorageItem
    let bytes: Int64

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.draggable(item.path) {
                HStack(spacing: 8) {
                    Image(systemName: item.iconSystemName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content
        }
    }
}

private struct LayoutKey: Equatable {
    struct Entry: Equatable {
        let id: String
        let bytes: Int64
        let children: Int
    }

    let size: CGSize
    let entries: [Entry]

    init(nodes: [StorageExplorerHierarchyNode], size: CGSize) {
        self.size = size
        var flattened: [Entry] = []
        func append(_ nodes: [StorageExplorerHierarchyNode]) {
            for node in nodes {
                flattened.append(Entry(id: node.id, bytes: node.bytes, children: node.children.count))
                append(node.children)
            }
        }
        append(nodes)
        entries = flattened
    }
}
