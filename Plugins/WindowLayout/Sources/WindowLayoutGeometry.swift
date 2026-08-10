import CoreGraphics
import Foundation

enum WindowLayoutGeometry {
    static let minimumSize = CGSize(width: 200, height: 120)
    private static let scaleFactor: CGFloat = 1.1

    static func targetFrame(
        action: WindowLayoutAction,
        visibleFrame V: CGRect,
        currentFrame: CGRect,
        inset: CGFloat
    ) -> CGRect {
        let raw: CGRect
        switch action {
        case .restore:
            return currentFrame
        case .maximize:
            raw = V
        case .almostMaximize:
            raw = V.insetBy(dx: inset, dy: inset)
        case .leftHalf:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width / 2, height: V.height)
        case .rightHalf:
            raw = CGRect(x: V.minX + V.width / 2, y: V.minY, width: V.width / 2, height: V.height)
        case .topHalf:
            raw = CGRect(x: V.minX, y: V.midY, width: V.width, height: V.height / 2)
        case .bottomHalf:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width, height: V.height / 2)
        case .centerHalf:
            raw = CGRect(x: V.midX - V.width / 4, y: V.minY, width: V.width / 2, height: V.height)
        case .leftThird:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width / 3, height: V.height)
        case .centerThird:
            raw = CGRect(x: V.minX + V.width / 3, y: V.minY, width: V.width / 3, height: V.height)
        case .rightThird:
            raw = CGRect(x: V.minX + 2 * V.width / 3, y: V.minY, width: V.width / 3, height: V.height)
        case .leftTwoThirds:
            raw = CGRect(x: V.minX, y: V.minY, width: 2 * V.width / 3, height: V.height)
        case .rightTwoThirds:
            raw = CGRect(x: V.minX + V.width / 3, y: V.minY, width: 2 * V.width / 3, height: V.height)
        case .topLeftQuarter:
            raw = CGRect(x: V.minX, y: V.midY, width: V.width / 2, height: V.height / 2)
        case .topRightQuarter:
            raw = CGRect(x: V.midX, y: V.midY, width: V.width / 2, height: V.height / 2)
        case .bottomLeftQuarter:
            raw = CGRect(x: V.minX, y: V.minY, width: V.width / 2, height: V.height / 2)
        case .bottomRightQuarter:
            raw = CGRect(x: V.midX, y: V.minY, width: V.width / 2, height: V.height / 2)
        case .grow:
            raw = scaled(currentFrame, by: scaleFactor, within: V)
        case .shrink:
            raw = scaled(currentFrame, by: 1 / scaleFactor, within: V)
        case .center:
            raw = CGRect(
                x: V.midX - currentFrame.width / 2,
                y: V.midY - currentFrame.height / 2,
                width: currentFrame.width,
                height: currentFrame.height
            )
        }
        return clamp(raw, within: V)
    }

    private static func scaled(_ frame: CGRect, by factor: CGFloat, within _: CGRect) -> CGRect {
        let width = frame.width * factor
        let height = frame.height * factor
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func clamp(_ frame: CGRect, within V: CGRect) -> CGRect {
        let width = min(max(frame.width.rounded(), minimumSize.width), V.width)
        let height = min(max(frame.height.rounded(), minimumSize.height), V.height)
        var x = frame.minX.rounded()
        var y = frame.minY.rounded()
        if x < V.minX { x = V.minX }
        if y < V.minY { y = V.minY }
        if x + width > V.maxX { x = V.maxX - width }
        if y + height > V.maxY { y = V.maxY - height }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
