import AppKit
import MacToolsPluginKit

extension WindowSnapGeometry {
    /// Computes a frame for a stored app-window position within `visibleFrame`.
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
            let origin = CGPoint(
                x: visibleFrame.minX + travelX * clampedX,
                y: visibleFrame.minY + travelY * clampedY
            )
            return clampedFrame(CGRect(origin: origin, size: size), in: visibleFrame)
        }
    }
}
