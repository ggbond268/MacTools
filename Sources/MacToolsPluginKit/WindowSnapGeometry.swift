import AppKit
import Foundation

public enum WindowSnapGuideRole: String, CaseIterable, Sendable, Equatable {
    case leftEdge
    case rightEdge
    case topEdge
}

public enum WindowSnapGuideOrientation: Sendable, Equatable {
    case vertical
    case horizontal
}

public struct WindowSnapGuide: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: WindowSnapGuideRole
    public let orientation: WindowSnapGuideOrientation
    public let start: CGPoint
    public let end: CGPoint
    public let isHighlighted: Bool

    public init(
        id: String,
        role: WindowSnapGuideRole,
        orientation: WindowSnapGuideOrientation,
        start: CGPoint,
        end: CGPoint,
        isHighlighted: Bool
    ) {
        self.id = id
        self.role = role
        self.orientation = orientation
        self.start = start
        self.end = end
        self.isHighlighted = isHighlighted
    }
}

public struct WindowSnapResult: Equatable, Sendable {
    public let defaultFrame: CGRect
    public let snappedFrame: CGRect
    public let isSnappingX: Bool
    public let isSnappingY: Bool
    public let guides: [WindowSnapGuide]

    public var isFullySnapped: Bool {
        isSnappingX && isSnappingY
    }
}

public enum WindowSnapGeometry {
    public static let defaultThreshold: CGFloat = 20
    public static let defaultHysteresis: CGFloat = 4

    /// Calculates the default window frame centered horizontally and vertically within `visibleFrame`.
    /// Matches `StandaloneCommandPaletteLayout.frame`.
    public static func defaultFrame(
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
    public static func clampedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
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
    public static func calculate(
        proposedFrame: CGRect,
        contentSize: CGSize,
        visibleFrame: CGRect,
        referenceInsets: NSEdgeInsets = NSEdgeInsets(),
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

        let referenceFrame = CGRect(
            x: target.minX + referenceInsets.left,
            y: target.minY + referenceInsets.bottom,
            width: max(0, target.width - referenceInsets.left - referenceInsets.right),
            height: max(0, target.height - referenceInsets.top - referenceInsets.bottom)
        )
        let leftGuide = WindowSnapGuide(
            id: "guide.left",
            role: .leftEdge,
            orientation: .vertical,
            start: CGPoint(x: referenceFrame.minX, y: visibleFrame.minY),
            end: CGPoint(x: referenceFrame.minX, y: visibleFrame.maxY),
            isHighlighted: isSnappingX
        )
        let rightGuide = WindowSnapGuide(
            id: "guide.right",
            role: .rightEdge,
            orientation: .vertical,
            start: CGPoint(x: referenceFrame.maxX, y: visibleFrame.minY),
            end: CGPoint(x: referenceFrame.maxX, y: visibleFrame.maxY),
            isHighlighted: isSnappingX
        )
        let topGuide = WindowSnapGuide(
            id: "guide.top",
            role: .topEdge,
            orientation: .horizontal,
            start: CGPoint(x: visibleFrame.minX, y: referenceFrame.maxY),
            end: CGPoint(x: visibleFrame.maxX, y: referenceFrame.maxY),
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
    public static func normalizedPoint(for frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        let travelX = max(0, visibleFrame.width - frame.width)
        let travelY = max(0, visibleFrame.height - frame.height)

        let normX: CGFloat = travelX > 0 ? (frame.minX - visibleFrame.minX) / travelX : 0.5
        let normY: CGFloat = travelY > 0 ? (frame.minY - visibleFrame.minY) / travelY : 0.5

        return CGPoint(
            x: min(max(normX, 0), 1),
            y: min(max(normY, 0), 1)
        )
    }

}
