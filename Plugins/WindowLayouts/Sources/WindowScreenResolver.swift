import CoreGraphics
import Foundation

struct WindowScreenResolver {
    func screen(for windowFrame: CGRect, among screens: [WindowScreen]) -> WindowScreen? {
        guard !screens.isEmpty else {
            return nil
        }

        let ranked = screens.enumerated().map { index, screen in
            let intersection = windowFrame.intersection(screen.frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (index: index, screen: screen, intersectionArea: area)
        }
        if let intersecting = ranked.max(by: { lhs, rhs in
            if lhs.intersectionArea == rhs.intersectionArea {
                return lhs.index > rhs.index
            }
            return lhs.intersectionArea < rhs.intersectionArea
        }), intersecting.intersectionArea > 0 {
            return intersecting.screen
        }

        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return ranked.min { lhs, rhs in
            let lhsDistance = squaredDistance(from: center, to: lhs.screen.frame)
            let rhsDistance = squaredDistance(from: center, to: rhs.screen.frame)
            if lhsDistance == rhsDistance {
                return lhs.index < rhs.index
            }
            return lhsDistance < rhsDistance
        }?.screen
    }

    func adjacentScreen(
        to currentScreen: WindowScreen,
        direction: WindowLayoutOperation,
        among screens: [WindowScreen]
    ) -> WindowScreen? {
        guard screens.count > 1 else {
            return nil
        }
        let ordered = screens.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            if lhs.frame.minY != rhs.frame.minY {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.id < rhs.id
        }
        guard let currentIndex = ordered.firstIndex(where: { $0.id == currentScreen.id }) else {
            return nil
        }
        switch direction {
        case .moveToNextDisplay:
            return ordered[(currentIndex + 1) % ordered.count]
        case .moveToPreviousDisplay:
            return ordered[(currentIndex - 1 + ordered.count) % ordered.count]
        default:
            return nil
        }
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
