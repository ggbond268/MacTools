import CoreGraphics
import Foundation

struct WindowLayoutCalculator {
    func halfCycleFrames(
        for operation: WindowLayoutOperation,
        windowFrame: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> [CGRect] {
        switch operation {
        case .leftHalf:
            return horizontalCycleFrames(
                pinnedToLeadingEdge: true,
                windowFrame: windowFrame,
                visibleFrame: visibleFrame,
                gap: gap
            )
        case .rightHalf:
            return horizontalCycleFrames(
                pinnedToLeadingEdge: false,
                windowFrame: windowFrame,
                visibleFrame: visibleFrame,
                gap: gap
            )
        case .topHalf:
            return verticalCycleFrames(
                pinnedToLeadingEdge: true,
                visibleFrame: visibleFrame,
                gap: gap
            )
        case .bottomHalf:
            return verticalCycleFrames(
                pinnedToLeadingEdge: false,
                visibleFrame: visibleFrame,
                gap: gap
            )
        default:
            return []
        }
    }

    func placementFrame(
        for operation: WindowLayoutOperation,
        windowFrame: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> CGRect? {
        switch operation {
        case .toggleFullScreen:
            return nil
        case .leftHalf:
            return gridFrame(column: 0, columnSpan: 1, columns: 2, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .rightHalf:
            return gridFrame(column: 1, columnSpan: 1, columns: 2, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .topHalf:
            return gridFrame(column: 0, columnSpan: 1, columns: 1, row: 0, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .bottomHalf:
            return gridFrame(column: 0, columnSpan: 1, columns: 1, row: 1, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .topLeftQuarter:
            return gridFrame(column: 0, columnSpan: 1, columns: 2, row: 0, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .topRightQuarter:
            return gridFrame(column: 1, columnSpan: 1, columns: 2, row: 0, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .bottomLeftQuarter:
            return gridFrame(column: 0, columnSpan: 1, columns: 2, row: 1, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .bottomRightQuarter:
            return gridFrame(column: 1, columnSpan: 1, columns: 2, row: 1, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .maximize:
            return insetFrame(visibleFrame.standardized, by: gap)
        case .maximizeHeight:
            let bounds = insetFrame(visibleFrame.standardized, by: gap)
            return CGRect(x: windowFrame.minX, y: bounds.minY, width: windowFrame.width, height: bounds.height)
        case .maximizeWidth:
            let bounds = insetFrame(visibleFrame.standardized, by: gap)
            return CGRect(x: bounds.minX, y: windowFrame.minY, width: bounds.width, height: windowFrame.height)
        case .center:
            return CGRect(
                x: visibleFrame.midX - windowFrame.width / 2,
                y: visibleFrame.midY - windowFrame.height / 2,
                width: windowFrame.width,
                height: windowFrame.height
            )
        case .reasonableSize:
            let bounds = insetFrame(visibleFrame.standardized, by: gap)
            let size = CGSize(width: min(bounds.width * 0.6, 1025), height: min(bounds.height * 0.6, 900))
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        case .moveToTopEdge:
            return movePreservingSize(windowFrame, to: .top, inside: insetFrame(visibleFrame.standardized, by: gap))
        case .moveToBottomEdge:
            return movePreservingSize(windowFrame, to: .bottom, inside: insetFrame(visibleFrame.standardized, by: gap))
        case .moveToLeftEdge:
            return movePreservingSize(windowFrame, to: .left, inside: insetFrame(visibleFrame.standardized, by: gap))
        case .moveToRightEdge:
            return movePreservingSize(windowFrame, to: .right, inside: insetFrame(visibleFrame.standardized, by: gap))
        case .firstThird:
            return gridFrame(column: 0, columnSpan: 1, columns: 3, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .firstTwoThirds:
            return gridFrame(column: 0, columnSpan: 2, columns: 3, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .centerThird:
            return gridFrame(column: 1, columnSpan: 1, columns: 3, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .lastTwoThirds:
            return gridFrame(column: 1, columnSpan: 2, columns: 3, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .lastThird:
            return gridFrame(column: 2, columnSpan: 1, columns: 3, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .firstFourth:
            return gridFrame(column: 0, columnSpan: 1, columns: 4, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .secondFourth:
            return gridFrame(column: 1, columnSpan: 1, columns: 4, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .thirdFourth:
            return gridFrame(column: 2, columnSpan: 1, columns: 4, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .lastFourth:
            return gridFrame(column: 3, columnSpan: 1, columns: 4, row: 0, rowSpan: 1, rows: 1, in: visibleFrame, gap: gap)
        case .topLeftSixth:
            return gridFrame(column: 0, columnSpan: 1, columns: 3, row: 0, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .topCenterSixth:
            return gridFrame(column: 1, columnSpan: 1, columns: 3, row: 0, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .topRightSixth:
            return gridFrame(column: 2, columnSpan: 1, columns: 3, row: 0, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .bottomLeftSixth:
            return gridFrame(column: 0, columnSpan: 1, columns: 3, row: 1, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .bottomCenterSixth:
            return gridFrame(column: 1, columnSpan: 1, columns: 3, row: 1, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .bottomRightSixth:
            return gridFrame(column: 2, columnSpan: 1, columns: 3, row: 1, rowSpan: 1, rows: 2, in: visibleFrame, gap: gap)
        case .moveToNextDisplay, .moveToPreviousDisplay, .restorePreviousFrame:
            return nil
        }
    }

    func customFrame(
        for command: WindowCustomCommand,
        windowFrame: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> CGRect {
        let bounds = insetFrame(visibleFrame.standardized, by: gap)
        let width = resolved(command.width, current: windowFrame.width, available: bounds.width)
        let height = resolved(command.height, current: windowFrame.height, available: bounds.height)
        let size = CGSize(width: width, height: height)
        let origin = anchoredOrigin(command.anchor, size: size, in: bounds)
        return clampPosition(
            CGRect(x: origin.x + command.offsetX, y: origin.y + command.offsetY, width: size.width, height: size.height),
            inside: bounds
        )
    }

    func movedFrame(
        _ windowFrame: CGRect,
        from sourceVisibleFrame: CGRect,
        to destinationVisibleFrame: CGRect,
        preservingSize: Bool = false
    ) -> CGRect {
        let source = sourceVisibleFrame.standardized
        let destination = destinationVisibleFrame.standardized
        guard source.width > 0, source.height > 0,
              destination.width > 0, destination.height > 0
        else {
            return destination
        }

        let widthRatio = max(0, windowFrame.width / source.width)
        let heightRatio = max(0, windowFrame.height / source.height)
        let destinationSize = preservingSize
            ? windowFrame.size
            : CGSize(
                width: source.width == destination.width
                    ? min(destination.width, max(0, windowFrame.width))
                    : min(destination.width, destination.width * widthRatio),
                height: source.height == destination.height
                    ? min(destination.height, max(0, windowFrame.height))
                    : min(destination.height, destination.height * heightRatio)
            )
        let sourceTravelX = source.width - windowFrame.width
        let sourceTravelY = source.height - windowFrame.height
        let relativeX = relativePosition(
            value: windowFrame.minX - source.minX,
            availableDistance: sourceTravelX
        )
        let relativeY = relativePosition(
            value: windowFrame.minY - source.minY,
            availableDistance: sourceTravelY
        )
        let destinationTravelX = destination.width - destinationSize.width
        let destinationTravelY = destination.height - destinationSize.height
        let proposed = CGRect(
            x: destination.minX + destinationTravelX * relativeX,
            y: destination.minY + destinationTravelY * relativeY,
            width: destinationSize.width,
            height: destinationSize.height
        )
        return preservingSize
            ? restoreReachableFrame(proposed, inside: destination)
            : clamp(proposed, inside: destination)
    }

    func clamp(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        let bounds = bounds.standardized
        let width = min(max(0, frame.width), bounds.width)
        let height = min(max(0, frame.height), bounds.height)
        let maximumX = bounds.maxX - width
        let maximumY = bounds.maxY - height
        return CGRect(
            x: min(max(frame.minX, bounds.minX), maximumX),
            y: min(max(frame.minY, bounds.minY), maximumY),
            width: width,
            height: height
        )
    }

    /// Keeps the original size while ensuring the window's top edge remains reachable.
    func restoreReachableFrame(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        let bounds = bounds.standardized
        let minimumX = min(bounds.minX, bounds.maxX - frame.width)
        let maximumX = max(bounds.minX, bounds.maxX - frame.width)
        let maximumY = max(bounds.minY, bounds.maxY - frame.height)
        return CGRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, bounds.minY), maximumY),
            width: frame.width,
            height: frame.height
        )
    }

    private func insetFrame(_ frame: CGRect, by requestedGap: CGFloat) -> CGRect {
        let maximumGap = max(0, min(frame.width, frame.height) / 2 - 0.5)
        let gap = min(max(0, requestedGap), maximumGap)
        return frame.insetBy(dx: gap, dy: gap)
    }

    private enum Edge { case top, bottom, left, right }

    private func movePreservingSize(_ frame: CGRect, to edge: Edge, inside bounds: CGRect) -> CGRect {
        var result = clampPosition(frame, inside: bounds)
        switch edge {
        case .top: result.origin.y = bounds.minY
        case .bottom: result.origin.y = bounds.maxY - result.height
        case .left: result.origin.x = bounds.minX
        case .right: result.origin.x = bounds.maxX - result.width
        }
        return result
    }

    private func clampPosition(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        let bounds = bounds.standardized
        let minimumX = min(bounds.minX, bounds.maxX - frame.width)
        let maximumX = max(bounds.minX, bounds.maxX - frame.width)
        let minimumY = min(bounds.minY, bounds.maxY - frame.height)
        let maximumY = max(bounds.minY, bounds.maxY - frame.height)
        return CGRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY),
            width: frame.width,
            height: frame.height
        )
    }

    private func gridFrame(
        column: Int,
        columnSpan: Int,
        columns: Int,
        row: Int,
        rowSpan: Int,
        rows: Int,
        in visibleFrame: CGRect,
        gap requestedGap: CGFloat
    ) -> CGRect {
        let frame = visibleFrame.standardized
        let maximumGap = max(0, min(frame.width, frame.height) / 2 - 0.5)
        let gap = min(max(0, requestedGap), maximumGap)
        let rawMinX = frame.minX + floor(frame.width * CGFloat(column) / CGFloat(columns))
        let rawMaxX = column + columnSpan == columns
            ? frame.maxX
            : frame.minX + floor(frame.width * CGFloat(column + columnSpan) / CGFloat(columns))
        let rawMinY = frame.minY + floor(frame.height * CGFloat(row) / CGFloat(rows))
        let rawMaxY = row + rowSpan == rows
            ? frame.maxY
            : frame.minY + floor(frame.height * CGFloat(row + rowSpan) / CGFloat(rows))
        let leftInset = column == 0 ? gap : gap / 2
        let rightInset = column + columnSpan == columns ? gap : gap / 2
        let topInset = row == 0 ? gap : gap / 2
        let bottomInset = row + rowSpan == rows ? gap : gap / 2
        return CGRect(
            x: rawMinX + leftInset,
            y: rawMinY + topInset,
            width: rawMaxX - rawMinX - leftInset - rightInset,
            height: rawMaxY - rawMinY - topInset - bottomInset
        )
    }

    private func horizontalCycleFrames(
        pinnedToLeadingEdge: Bool,
        windowFrame: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> [CGRect] {
        let operations: [WindowLayoutOperation] = pinnedToLeadingEdge
            ? [.leftHalf, .firstTwoThirds, .firstThird]
            : [.rightHalf, .lastTwoThirds, .lastThird]
        return operations.compactMap {
            placementFrame(
                for: $0,
                windowFrame: windowFrame,
                visibleFrame: visibleFrame,
                gap: gap
            )
        }
    }

    private func verticalCycleFrames(
        pinnedToLeadingEdge: Bool,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> [CGRect] {
        let row = pinnedToLeadingEdge ? 0 : 1
        let twoThirdsRow = pinnedToLeadingEdge ? 0 : 1
        let oneThirdRow = pinnedToLeadingEdge ? 0 : 2
        return [
            gridFrame(
                column: 0,
                columnSpan: 1,
                columns: 1,
                row: row,
                rowSpan: 1,
                rows: 2,
                in: visibleFrame,
                gap: gap
            ),
            gridFrame(
                column: 0,
                columnSpan: 1,
                columns: 1,
                row: twoThirdsRow,
                rowSpan: 2,
                rows: 3,
                in: visibleFrame,
                gap: gap
            ),
            gridFrame(
                column: 0,
                columnSpan: 1,
                columns: 1,
                row: oneThirdRow,
                rowSpan: 1,
                rows: 3,
                in: visibleFrame,
                gap: gap
            ),
        ]
    }

    private func resolved(_ dimension: WindowLayoutDimension, current: CGFloat, available: CGFloat) -> CGFloat {
        switch dimension {
        case .current:
            max(1, current)
        case let .points(value):
            min(max(1, value), available)
        case let .fraction(value):
            min(max(1, available * min(max(value, 0.05), 1)), available)
        }
    }

    private func anchoredOrigin(_ anchor: WindowLayoutAnchor, size: CGSize, in bounds: CGRect) -> CGPoint {
        let left = bounds.minX
        let centerX = bounds.midX - size.width / 2
        let right = bounds.maxX - size.width
        let top = bounds.minY
        let centerY = bounds.midY - size.height / 2
        let bottom = bounds.maxY - size.height
        return switch anchor {
        case .topLeft: CGPoint(x: left, y: top)
        case .top: CGPoint(x: centerX, y: top)
        case .topRight: CGPoint(x: right, y: top)
        case .left: CGPoint(x: left, y: centerY)
        case .center: CGPoint(x: centerX, y: centerY)
        case .right: CGPoint(x: right, y: centerY)
        case .bottomLeft: CGPoint(x: left, y: bottom)
        case .bottom: CGPoint(x: centerX, y: bottom)
        case .bottomRight: CGPoint(x: right, y: bottom)
        }
    }

    private func relativePosition(value: CGFloat, availableDistance: CGFloat) -> CGFloat {
        guard availableDistance > 0 else {
            return 0.5
        }
        return min(max(value / availableDistance, 0), 1)
    }
}
