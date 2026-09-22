import SwiftUI

/// One geometry contract for SwiftUI controls, AppKit hit testing, and cursors.
struct PanelLayoutItemControlsLayout {
    let isVertical: Bool
    let isCompact: Bool
    let buttonSide: CGFloat
    let spacing: CGFloat = 8

    init(size: CGSize) {
        isVertical = size.width < 120 && size.height > size.width
        let main = isVertical ? size.height : size.width
        let cross = isVertical ? size.width : size.height
        let expandedSide = min(32, floor((main - 8 - 16) / 3), cross - 8)
        // Do not shrink three controls into tiny targets. A single centered menu
        // leaves a continuous drag area around compact tiles without resizing them.
        isCompact = expandedSide < 24
        buttonSide = isCompact ? max(0, min(24, size.width, size.height)) : expandedSide
    }

    var controlCount: Int { isCompact ? 1 : 3 }

    var size: CGSize {
        if isCompact { return CGSize(width: buttonSide, height: buttonSide) }
        let length = buttonSide * 3 + spacing * 2
        return isVertical ? CGSize(width: buttonSide, height: length) : CGSize(width: length, height: buttonSide)
    }

    func buttonFrame(at index: Int, rightToLeft: Bool = false) -> CGRect {
        let offset = CGFloat(index) * (buttonSide + spacing)
        let origin = isCompact ? CGPoint.zero : isVertical ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0)
        return CGRect(x: rightToLeft ? size.width - origin.x - buttonSide : origin.x,
                      y: origin.y, width: buttonSide, height: buttonSide)
    }

    func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    static func frame(in bounds: CGRect) -> CGRect { Self(size: bounds.size).frame(in: bounds) }

    func buttonFrames(in bounds: CGRect, rightToLeft: Bool) -> [CGRect] {
        let origin = frame(in: bounds).origin
        return (0..<controlCount).map {
            buttonFrame(at: $0, rightToLeft: rightToLeft).offsetBy(dx: origin.x, dy: origin.y)
        }
    }
}

struct PanelLayoutControls: Layout {
    let metrics: PanelLayoutItemControlsLayout
    let rightToLeft: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { metrics.size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            let frame = metrics.buttonFrame(at: index, rightToLeft: rightToLeft)
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
