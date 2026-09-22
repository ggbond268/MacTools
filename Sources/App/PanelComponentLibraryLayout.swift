import CoreGraphics

/// Pack actual preview bounds at one scale, with room for two full-width panels.
struct PanelComponentLibraryLayout {
    static let spacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 20
    static let previewPadding: CGFloat = 6
    private static let tolerance: CGFloat = 0.001

    let width: CGFloat
    let scale: CGFloat
    private(set) var frames: [CGRect] = []
    private(set) var height: CGFloat = 0

    init(sourceSizes: [CGSize], availableWidth: CGFloat) {
        width = availableWidth.isFinite ? max(0, availableWidth) : 0
        scale = max(0, (width - Self.spacing - Self.previewPadding * 4) / (2 * ComponentPanelLayout.gridWidth))
        guard scale > 0 else { return }

        // Include a trailing gutter in the skyline, but not in the visible bounds.
        // Each segment records the lowest free height over a horizontal interval.
        var skyline = [Segment(minX: 0, maxX: width + Self.spacing, bottom: 0)]
        for source in sourceSizes {
            let size = CGSize(width: source.width * scale + Self.previewPadding * 2,
                              height: source.height * scale + Self.previewPadding * 2)
            var origin = CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
            for (index, segment) in skyline.enumerated() {
                let end = segment.minX + size.width + Self.spacing
                guard end <= width + Self.spacing + Self.tolerance else { break }
                var y: CGFloat = 0
                for covered in skyline[index...] {
                    guard covered.minX < end - Self.tolerance else { break }
                    y = max(y, covered.bottom)
                }
                // Topmost first, then leftmost; never enlarge a narrow preview's slot.
                if y < origin.y - Self.tolerance {
                    origin = CGPoint(x: segment.minX, y: y)
                }
                if y == 0 { break }
            }
            let frame = CGRect(origin: origin, size: size)
            frames.append(frame)
            height = max(height, frame.maxY)
            skyline = Self.inserting(frame, into: skyline)
        }
    }

    private struct Segment {
        let minX: CGFloat
        let maxX: CGFloat
        let bottom: CGFloat
    }

    private static func inserting(_ frame: CGRect, into skyline: [Segment]) -> [Segment] {
        let start = frame.minX
        let end = frame.maxX + spacing
        let bottom = frame.maxY + spacing
        var updated: [Segment] = []

        func append(_ segment: Segment) {
            guard segment.maxX - segment.minX > tolerance else { return }
            if let last = updated.last, abs(last.bottom - segment.bottom) < tolerance {
                updated[updated.count - 1] = Segment(minX: last.minX, maxX: segment.maxX, bottom: last.bottom)
            } else {
                updated.append(segment)
            }
        }

        for segment in skyline {
            if segment.maxX <= start + tolerance || segment.minX >= end - tolerance {
                append(segment)
            } else {
                append(Segment(minX: segment.minX, maxX: start, bottom: segment.bottom))
                append(Segment(minX: max(start, segment.minX), maxX: min(end, segment.maxX), bottom: bottom))
                append(Segment(minX: end, maxX: segment.maxX, bottom: segment.bottom))
            }
        }
        return updated
    }
}
