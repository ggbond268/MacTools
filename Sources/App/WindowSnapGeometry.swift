import AppKit
import Foundation

enum WindowSnapGuideRole: String, CaseIterable, Sendable, Equatable {
    case leftEdge
    case rightEdge
    case topEdge
}

enum WindowSnapGuideOrientation: Sendable, Equatable {
    case vertical
    case horizontal
}

struct WindowSnapGuide: Identifiable, Equatable, Sendable {
    let id: String
    let role: WindowSnapGuideRole
    let orientation: WindowSnapGuideOrientation
    let start: CGPoint
    let end: CGPoint
    let isHighlighted: Bool
}

struct WindowSnapResult: Equatable, Sendable {
    let defaultFrame: CGRect
    let snappedFrame: CGRect
    let isSnappingX: Bool
    let isSnappingY: Bool
    let guides: [WindowSnapGuide]

    var isFullySnapped: Bool {
        isSnappingX && isSnappingY
    }
}

enum WindowSnapGeometry {
    static let defaultThreshold: CGFloat = 20
    static let defaultHysteresis: CGFloat = 4

    /// Calculates the default window frame centered horizontally and vertically within `visibleFrame`.
    /// Matches `StandaloneCommandPaletteLayout.frame`.
    static func defaultFrame(
        contentSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let size = CGSize(
            width: min(contentSize.width, visibleFrame.width),
            height: min(contentSize.height, visibleFrame.height)
        )
        let proposedOrigin = CGPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )
        let origin = CGPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        return CGRect(origin: origin, size: size)
    }

    /// Clamps a frame completely inside `visibleFrame` so it is never offscreen or inaccessible.
    static func clampedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let size = CGSize(
            width: min(frame.width, visibleFrame.width),
            height: min(frame.height, visibleFrame.height)
        )
        let originX: CGFloat
        if size.width >= visibleFrame.width {
            originX = visibleFrame.minX
        } else {
            originX = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        }

        let originY: CGFloat
        if size.height >= visibleFrame.height {
            originY = visibleFrame.minY
        } else {
            originY = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        }

        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// Calculates snap state, highlighted guides, and snapped frame given a proposed frame.
    static func calculate(
        proposedFrame: CGRect,
        contentSize: CGSize,
        visibleFrame: CGRect,
        threshold: CGFloat = defaultThreshold,
        hysteresis: CGFloat = defaultHysteresis,
        currentlySnappingX: Bool = false,
        currentlySnappingY: Bool = false
    ) -> WindowSnapResult {
        let target = defaultFrame(contentSize: contentSize, visibleFrame: visibleFrame)

        let thresholdX = currentlySnappingX ? (threshold + hysteresis) : threshold
        let thresholdY = currentlySnappingY ? (threshold + hysteresis) : threshold

        let distanceX = abs(proposedFrame.midX - target.midX)
        let isSnappingX = distanceX <= thresholdX

        let distanceY = abs(proposedFrame.maxY - target.maxY)
        let isSnappingY = distanceY <= thresholdY

        let snappedX = isSnappingX ? target.minX : proposedFrame.minX
        let snappedY = isSnappingY ? target.minY : proposedFrame.minY

        let unsnappedSize = CGSize(
            width: min(contentSize.width, visibleFrame.width),
            height: min(contentSize.height, visibleFrame.height)
        )
        let rawSnappedFrame = CGRect(
            origin: CGPoint(x: snappedX, y: snappedY),
            size: unsnappedSize
        )
        let snappedFrame = clampedFrame(rawSnappedFrame, in: visibleFrame)

        let leftGuide = WindowSnapGuide(
            id: "guide.left",
            role: .leftEdge,
            orientation: .vertical,
            start: CGPoint(x: target.minX, y: visibleFrame.minY),
            end: CGPoint(x: target.minX, y: visibleFrame.maxY),
            isHighlighted: isSnappingX
        )
        let rightGuide = WindowSnapGuide(
            id: "guide.right",
            role: .rightEdge,
            orientation: .vertical,
            start: CGPoint(x: target.maxX, y: visibleFrame.minY),
            end: CGPoint(x: target.maxX, y: visibleFrame.maxY),
            isHighlighted: isSnappingX
        )
        let topGuide = WindowSnapGuide(
            id: "guide.top",
            role: .topEdge,
            orientation: .horizontal,
            start: CGPoint(x: visibleFrame.minX, y: target.maxY),
            end: CGPoint(x: visibleFrame.maxX, y: target.maxY),
            isHighlighted: isSnappingY
        )

        return WindowSnapResult(
            defaultFrame: target,
            snappedFrame: snappedFrame,
            isSnappingX: isSnappingX,
            isSnappingY: isSnappingY,
            guides: [leftGuide, rightGuide, topGuide]
        )
    }

    /// Converts a window frame within `visibleFrame` into a normalized point in `0.0...1.0`.
    static func normalizedPoint(for frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        let travelX = max(0, visibleFrame.width - frame.width)
        let travelY = max(0, visibleFrame.height - frame.height)

        let normX: CGFloat = travelX > 0 ? (frame.minX - visibleFrame.minX) / travelX : 0.5
        let normY: CGFloat = travelY > 0 ? (frame.minY - visibleFrame.minY) / travelY : 0.5

        return CGPoint(
            x: min(max(normX, 0), 1),
            y: min(max(normY, 0), 1)
        )
    }

    /// Computes window frame for a given position (`.defaultAnchor` or `.custom(normalizedPoint)`) within `visibleFrame`.
    static func frame(
        for position: WindowPosition,
        contentSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        switch position {
        case .defaultAnchor:
            return defaultFrame(contentSize: contentSize, visibleFrame: visibleFrame)
        case let .custom(normalizedPoint):
            let size = CGSize(
                width: min(contentSize.width, visibleFrame.width),
                height: min(contentSize.height, visibleFrame.height)
            )
            let travelX = max(0, visibleFrame.width - size.width)
            let travelY = max(0, visibleFrame.height - size.height)

            let clampedX = min(max(normalizedPoint.x, 0), 1)
            let clampedY = min(max(normalizedPoint.y, 0), 1)

            let originX = visibleFrame.minX + travelX * clampedX
            let originY = visibleFrame.minY + travelY * clampedY

            return clampedFrame(
                CGRect(origin: CGPoint(x: originX, y: originY), size: size),
                in: visibleFrame
            )
        }
    }
}
