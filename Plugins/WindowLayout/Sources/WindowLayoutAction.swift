import CoreGraphics
import Foundation

enum WindowLayoutAction: String, CaseIterable, Sendable {
    case maximize
    case almostMaximize = "almost-maximize"
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case centerHalf = "center-half"
    case leftThird = "left-third"
    case centerThird = "center-third"
    case rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds"
    case rightTwoThirds = "right-two-thirds"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case grow
    case shrink
    case center
    case restore
}
