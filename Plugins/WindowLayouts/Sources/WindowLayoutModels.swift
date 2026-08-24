import CoreGraphics
import Foundation

enum WindowLayoutOperation: String, CaseIterable, Sendable {
    case toggleFullScreen = "toggle-full-screen"
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case maximize
    case maximizeHeight = "maximize-height"
    case maximizeWidth = "maximize-width"
    case center
    case reasonableSize = "reasonable-size"
    case moveToTopEdge = "move-to-top-edge"
    case moveToBottomEdge = "move-to-bottom-edge"
    case moveToLeftEdge = "move-to-left-edge"
    case moveToRightEdge = "move-to-right-edge"
    case firstThird = "first-third"
    case firstTwoThirds = "first-two-thirds"
    case centerThird = "center-third"
    case lastTwoThirds = "last-two-thirds"
    case lastThird = "last-third"
    case firstFourth = "first-fourth"
    case secondFourth = "second-fourth"
    case thirdFourth = "third-fourth"
    case lastFourth = "last-fourth"
    case topLeftSixth = "top-left-sixth"
    case topCenterSixth = "top-center-sixth"
    case topRightSixth = "top-right-sixth"
    case bottomLeftSixth = "bottom-left-sixth"
    case bottomCenterSixth = "bottom-center-sixth"
    case bottomRightSixth = "bottom-right-sixth"
    case moveToNextDisplay = "move-to-next-display"
    case moveToPreviousDisplay = "move-to-previous-display"
    case restorePreviousFrame = "restore-previous-frame"

    var requiresResize: Bool {
        switch self {
        case .toggleFullScreen,
             .center,
             .moveToTopEdge,
             .moveToBottomEdge,
             .moveToLeftEdge,
             .moveToRightEdge:
            false
        case .leftHalf,
             .rightHalf,
             .topHalf,
             .bottomHalf,
             .topLeftQuarter,
             .topRightQuarter,
             .bottomLeftQuarter,
             .bottomRightQuarter,
             .maximize,
             .maximizeHeight,
             .maximizeWidth,
             .reasonableSize,
             .firstThird,
             .firstTwoThirds,
             .centerThird,
             .lastTwoThirds,
             .lastThird,
             .firstFourth,
             .secondFourth,
             .thirdFourth,
             .lastFourth,
             .topLeftSixth,
             .topCenterSixth,
             .topRightSixth,
             .bottomLeftSixth,
             .bottomCenterSixth,
             .bottomRightSixth,
             .moveToNextDisplay,
             .moveToPreviousDisplay,
             .restorePreviousFrame:
            true
        }
    }

    var isDisplayMovement: Bool {
        self == .moveToNextDisplay || self == .moveToPreviousDisplay
    }

}

struct WindowLayoutExecutionOptions: Equatable, Sendable {
    let gap: CGFloat
    let cyclesHalves: Bool
    let respectsStageManager: Bool
}

enum WindowLayoutDimension: Codable, Equatable, Sendable {
    case current
    case points(CGFloat)
    case fraction(CGFloat)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case current, points, fraction }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .current:
            self = .current
        case .points:
            self = .points(try container.decode(CGFloat.self, forKey: .value))
        case .fraction:
            self = .fraction(try container.decode(CGFloat.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current:
            try container.encode(Kind.current, forKey: .kind)
        case let .points(value):
            try container.encode(Kind.points, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .fraction(value):
            try container.encode(Kind.fraction, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

enum WindowLayoutAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft = "top-left"
    case top
    case topRight = "top-right"
    case left
    case center
    case right
    case bottomLeft = "bottom-left"
    case bottom
    case bottomRight = "bottom-right"
}

struct WindowCustomCommand: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var width: WindowLayoutDimension
    var height: WindowLayoutDimension
    var anchor: WindowLayoutAnchor
    var offsetX: CGFloat
    var offsetY: CGFloat
    var allowExternalInvocation: Bool

    init(
        id: UUID = UUID(),
        name: String,
        width: WindowLayoutDimension = .fraction(0.6),
        height: WindowLayoutDimension = .fraction(0.6),
        anchor: WindowLayoutAnchor = .center,
        offsetX: CGFloat = 0,
        offsetY: CGFloat = 0,
        allowExternalInvocation: Bool = true
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.allowExternalInvocation = allowExternalInvocation
    }

    var actionID: String { "custom.\(id.uuidString.lowercased())" }
}

enum WindowShortcutPreset: String, Codable, CaseIterable, Sendable {
    case none
    case controlOption = "control-option"
    case optionCommand = "option-command"
    case controlOptionCommand = "control-option-command"

    init(storedValue: String?) {
        switch storedValue {
        case "raycast":
            self = .controlOption
        case "rectangle":
            self = .controlOptionCommand
        case let value:
            self = value.flatMap(Self.init(rawValue:)) ?? .none
        }
    }
}

struct WindowScreen: Equatable, Sendable {
    let id: String
    /// The transient display ID is retained only for runtime system calls.
    let directDisplayID: CGDirectDisplayID?
    /// Screen coordinates converted to the Accessibility top-left coordinate space.
    let frame: CGRect
    let visibleFrame: CGRect

    init(
        id: String,
        directDisplayID: CGDirectDisplayID? = nil,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.id = id
        self.directDisplayID = directDisplayID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

struct WindowIdentity: Hashable, Sendable {
    let processIdentifier: pid_t
    let token: String
}

enum WindowLayoutError: Error, Equatable {
    case executionCancelled
    case executionQueueFull
    case accessibilityRequired
    case noFocusedWindow
    case windowUnavailable
    case windowCannotMove
    case windowCannotResize
    case windowSizeConstrained
    case fullScreenUnsupported
    case customCommandUnavailable
    case noDisplay
    case noOtherDisplay
    case noPreviousFrame
    case frameReadFailed
    case frameWriteFailed
}
