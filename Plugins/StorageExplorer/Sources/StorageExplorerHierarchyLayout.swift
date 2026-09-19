import Foundation

struct StorageExplorerHierarchyNode: Identifiable, Equatable, Sendable {
    let item: StorageItem
    let bytes: Int64
    let children: [StorageExplorerHierarchyNode]
    let colorKey: String

    var id: String { item.path }
    var isAggregate: Bool { item.path.hasPrefix("group:other:") }
}

enum StorageExplorerHierarchyLayout {
    static func make(
        snapshot: StorageExplorerSnapshot,
        directory: String,
        metric: StorageExplorerMetric,
        excluding excludedPaths: Set<String>,
        otherName: String,
        maximumDepth: Int = 3
    ) -> [StorageExplorerHierarchyNode] {
        let excluded = excludedPaths.sorted()

        func isExcluded(_ path: String) -> Bool {
            excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        func adjustedBytes(_ item: StorageItem) -> Int64 {
            guard !isExcluded(item.path) else { return 0 }
            let removed = excluded.reduce(Int64(0)) { partial, path in
                guard path.hasPrefix(item.path + "/"), let selected = snapshot.items[path] else { return partial }
                return partial + metric.bytes(selected)
            }
            return max(0, metric.bytes(item) - removed)
        }

        func nodes(parentPath: String, depth: Int, colorKey: String?) -> [StorageExplorerHierarchyNode] {
            let parentBytes = snapshot.items[parentPath].map(adjustedBytes) ?? 0
            let children = snapshot.children(of: parentPath)
                .filter { adjustedBytes($0) > 0 }
                .sorted {
                    let lhs = adjustedBytes($0), rhs = adjustedBytes($1)
                    return lhs == rhs ? $0.path < $1.path : lhs > rhs
                }
            let limit = depth == 0 ? 48 : depth == 1 ? 18 : 10
            let visible = Array(children.prefix(limit))
            var result = visible.enumerated().map { index, item -> StorageExplorerHierarchyNode in
                // The completed snapshot is sorted deterministically by size and path. Top-level
                // rank drives a warm-to-cool palette, while descendants inherit their group color.
                let key = colorKey ?? "size-rank:\(index):\(item.path)"
                let nested = depth + 1 < maximumDepth && item.isDirectory && !item.isPackage
                    ? nodes(parentPath: item.path, depth: depth + 1, colorKey: key)
                    : []
                return StorageExplorerHierarchyNode(
                    item: item,
                    bytes: adjustedBytes(item),
                    children: nested,
                    colorKey: key
                )
            }
            let represented = result.reduce(Int64(0)) { $0 + $1.bytes }
            let remainder = max(0, parentBytes - represented)
            if remainder > 0 {
                let aggregate = StorageItem(
                    name: otherName,
                    path: "group:other:" + parentPath,
                    url: URL(fileURLWithPath: parentPath),
                    isDirectory: false,
                    size: remainder,
                    allocatedSize: remainder,
                    parentPath: parentPath
                )
                result.append(StorageExplorerHierarchyNode(
                    item: aggregate,
                    bytes: remainder,
                    children: [],
                    colorKey: colorKey ?? "size-rank:7:other"
                ))
            }
            return result
        }

        return nodes(parentPath: directory, depth: 0, colorKey: nil)
    }
}

struct StorageExplorerHierarchyRect: Identifiable, Equatable {
    let node: StorageExplorerHierarchyNode
    let rect: CGRect
    let depth: Int
    var id: String { node.id }
}

enum StorageExplorerHierarchyRectLayout {
    static func make(nodes: [StorageExplorerHierarchyNode], in bounds: CGRect) -> [StorageExplorerHierarchyRect] {
        var result: [StorageExplorerHierarchyRect] = []

        func append(_ nodes: [StorageExplorerHierarchyNode], in rect: CGRect, depth: Int) {
            let positive = nodes.filter { $0.bytes > 0 }
            guard !positive.isEmpty, rect.width > 2, rect.height > 2 else { return }
            let weights = positive.map { Double($0.bytes) }
            let boxes = partition(weights: weights, in: rect)
            for (node, box) in zip(positive, boxes) {
                result.append(StorageExplorerHierarchyRect(node: node, rect: box, depth: depth))
                guard !node.children.isEmpty else { continue }
                let header = min(26, max(18, box.height * 0.12))
                let inset = box.insetBy(dx: 4, dy: 4)
                let childRect = CGRect(
                    x: inset.minX,
                    y: inset.minY + header,
                    width: inset.width,
                    height: max(0, inset.height - header)
                )
                append(node.children, in: childRect, depth: depth + 1)
            }
        }

        append(nodes, in: bounds, depth: 0)
        return result
    }

    private static func partition(weights: [Double], in rect: CGRect) -> [CGRect] {
        guard !weights.isEmpty else { return [] }
        var result = Array(repeating: CGRect.zero, count: weights.count)

        func split(_ range: Range<Int>, _ box: CGRect) {
            if range.count == 1 {
                result[range.lowerBound] = box
                return
            }
            let total = range.reduce(0.0) { $0 + weights[$1] }
            guard total > 0 else { return }
            var subtotal = 0.0
            var pivot = range.lowerBound
            repeat {
                subtotal += weights[pivot]
                pivot += 1
            } while pivot < range.upperBound - 1 && subtotal < total / 2
            let fraction = subtotal / total
            let horizontal = box.width >= box.height
            let first = CGRect(
                x: box.minX,
                y: box.minY,
                width: horizontal ? box.width * fraction : box.width,
                height: horizontal ? box.height : box.height * fraction
            )
            let second = CGRect(
                x: horizontal ? first.maxX : box.minX,
                y: horizontal ? box.minY : first.maxY,
                width: horizontal ? box.width - first.width : box.width,
                height: horizontal ? box.height : box.height - first.height
            )
            split(range.lowerBound..<pivot, first)
            split(pivot..<range.upperBound, second)
        }

        split(weights.indices, rect)
        return result
    }
}
