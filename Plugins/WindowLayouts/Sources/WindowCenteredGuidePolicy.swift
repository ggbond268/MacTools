import CoreGraphics
import MacToolsPluginKit

struct WindowCenteredGuideSnapshot: Sendable {
    let frame: CGRect
    var isFullScreen = false
    var isMinimized = false
    var isHidden = false
    var canMove = true
    var isStandardWindow = true
    var isValid = true

    func isEligible(in usableFrame: CGRect) -> Bool {
        isValid && canMove && isStandardWindow && !isFullScreen && !isMinimized && !isHidden
            && WindowCenteredGuidePolicy.valid(frame) && WindowCenteredGuidePolicy.valid(usableFrame)
            && frame.width <= usableFrame.width && frame.height <= usableFrame.height
            && !WindowCenteredGuidePolicy.matches(frame, usableFrame, tolerance: 3)
    }
}

struct WindowCenteredGuidePolicy {
    let originalFrame: CGRect
    let originalPointer: CGPoint
    private(set) var hasMoved = false
    private(set) var isCancelled = false
    private var snappingX = false
    private var snappingY = false
    private var screenID: String?
    private var mismatchStartedAt: ContinuousClock.Instant?
    static let frameLagAllowance: Duration = .milliseconds(120)
    var isAwaitingCorrelatedFrame: Bool { mismatchStartedAt != nil }

    mutating func update(
        snapshot: WindowCenteredGuideSnapshot,
        pointer: CGPoint,
        usableFrame: CGRect,
        screenID: String,
        recentPointers: [CGPoint] = [],
        now: ContinuousClock.Instant = .now
    ) -> WindowSnapResult? {
        guard !isCancelled else { return nil }
        let frame = snapshot.frame
        guard snapshot.isEligible(in: usableFrame),
              abs(frame.width - originalFrame.width) <= 1,
              abs(frame.height - originalFrame.height) <= 1 else {
            isCancelled = true
            return nil
        }
        let movedX = frame.minX - originalFrame.minX
        let movedY = frame.minY - originalFrame.minY
        // AX may describe any recent point in the drag, rather than the pointer at
        // read completion. Only actual, bounded pointer history can establish motion.
        let correlatedPointer = (recentPointers + [pointer]).min { lhs, rhs in
            hypot(lhs.x - originalPointer.x - movedX, lhs.y - originalPointer.y - movedY)
                < hypot(rhs.x - originalPointer.x - movedX, rhs.y - originalPointer.y - movedY)
        } ?? pointer
        let dx = correlatedPointer.x - originalPointer.x
        let dy = correlatedPointer.y - originalPointer.y
        guard abs(dx - movedX) <= 6, abs(dy - movedY) <= 6 else {
            let startedAt = mismatchStartedAt ?? now
            mismatchStartedAt = startedAt
            if now - startedAt >= Self.frameLagAllowance { isCancelled = true }
            return nil
        }
        mismatchStartedAt = nil
        guard hasMoved || (hypot(dx, dy) >= 3 && hypot(movedX, movedY) >= 2) else { return nil }
        hasMoved = true
        if self.screenID != screenID {
            snappingX = false
            snappingY = false
            self.screenID = screenID
        }
        let result = WindowSnapGeometry.calculate(
            proposedFrame: frame,
            contentSize: frame.size,
            visibleFrame: usableFrame,
            currentlySnappingX: snappingX,
            currentlySnappingY: snappingY
        )
        snappingX = result.isSnappingX
        snappingY = result.isSnappingY
        return result
    }

    static func activeScreen(frame: CGRect, pointer: CGPoint, screens: [WindowScreen]) -> WindowScreen? {
        screens.first(where: { $0.frame.contains(pointer) })
            ?? WindowScreenResolver().screen(for: frame, among: screens)
    }

    static func appKitGuides(for result: WindowSnapResult, anchorMaximumY: CGFloat) -> [WindowSnapGuide] {
        result.guides.map { guide in
            // AX Y grows downward, so the shared top-edge role uses the target minimum Y.
            let startY = guide.role == .topEdge ? result.defaultFrame.minY : guide.start.y
            let endY = guide.role == .topEdge ? result.defaultFrame.minY : guide.end.y
            return WindowSnapGuide(
                id: guide.id, role: guide.role, orientation: guide.orientation,
                start: CGPoint(x: guide.start.x, y: anchorMaximumY - startY),
                end: CGPoint(x: guide.end.x, y: anchorMaximumY - endY),
                isHighlighted: guide.isHighlighted
            )
        }
    }

    static func canReleaseSnap(
        snapshot: WindowCenteredGuideSnapshot,
        expected: CGRect,
        target: CGRect,
        usableFrame: CGRect
    ) -> Bool {
        let limit = WindowSnapGeometry.defaultThreshold + WindowSnapGeometry.defaultHysteresis
        return snapshot.isEligible(in: usableFrame)
            && matches(snapshot.frame, expected, tolerance: 1)
            && valid(target) && target.size == snapshot.frame.size
            && target == WindowSnapGeometry.defaultFrame(contentSize: snapshot.frame.size, visibleFrame: usableFrame)
            && abs(snapshot.frame.minX - target.minX) <= limit
            && abs(snapshot.frame.minY - target.minY) <= limit
    }

    static func valid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

    static func matches(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}

/// Bounds both time and storage when high-rate input overtakes Accessibility reads.
struct WindowCenteredGuidePointerHistory {
    private var samples: [(point: CGPoint, time: ContinuousClock.Instant)] = []

    mutating func record(_ point: CGPoint, now: ContinuousClock.Instant = .now) {
        samples.removeAll { now - $0.time > WindowCenteredGuidePolicy.frameLagAllowance }
        samples.append((point, now))
        if samples.count > 128 { samples.removeFirst(samples.count - 128) }
    }

    func points(now: ContinuousClock.Instant = .now) -> [CGPoint] {
        samples.filter { now - $0.time <= WindowCenteredGuidePolicy.frameLagAllowance }.map(\.point)
    }
}
