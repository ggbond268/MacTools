import Foundation

struct AutoInputSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum AutoInputHUDSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }
}

enum AutoInputHUDPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case above
    case below
    case screenCenter
    case atPointer

    var id: String { rawValue }

    func isAvailable(isInteractive: Bool) -> Bool {
        self != .atPointer || isInteractive
    }
}

enum AutoInputHUDReminderLimits {
    static let minimumIntervalSeconds = 5
    static let maximumIntervalSeconds = 300
    static let defaultIntervalSeconds = 60
    static let minimumAppSwitchCount = 1
    static let maximumAppSwitchCount = 10
    static let defaultAppSwitchCount = 3

    static func normalizedIntervalSeconds(_ value: Int) -> Int {
        guard (minimumIntervalSeconds...maximumIntervalSeconds).contains(value) else {
            return defaultIntervalSeconds
        }
        return value
    }

    static func normalizedAppSwitchCount(_ value: Int) -> Int {
        guard (minimumAppSwitchCount...maximumAppSwitchCount).contains(value) else {
            return defaultAppSwitchCount
        }
        return value
    }
}

struct AutoInputHUDConfiguration: Equatable, Sendable {
    let size: AutoInputHUDSize
    let position: AutoInputHUDPosition
    let isInteractive: Bool

    init(
        size: AutoInputHUDSize,
        position: AutoInputHUDPosition,
        isInteractive: Bool = false
    ) {
        self.size = size
        self.position = position
        self.isInteractive = isInteractive
    }

    var effectivePosition: AutoInputHUDPosition {
        position.isAvailable(isInteractive: isInteractive) ? position : .automatic
    }
}

struct AutoInputApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let bundleURL: URL?
    let processIdentifier: pid_t?

    init(
        bundleIdentifier: String,
        displayName: String,
        bundleURL: URL?,
        processIdentifier: pid_t? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.processIdentifier = processIdentifier
    }
}

struct AutoInputRule: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }

    let bundleIdentifier: String
    var displayName: String
    var bundleURLString: String?
    var inputSourceID: String

    var bundleURL: URL? {
        bundleURLString.flatMap(URL.init(string:))
    }

    init(
        bundleIdentifier: String,
        displayName: String,
        bundleURL: URL?,
        inputSourceID: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURLString = bundleURL?.absoluteString
        self.inputSourceID = inputSourceID
    }
}

enum AutoInputSwitchReason: Equatable {
    case fixedRule
    case remembered
}

struct AutoInputTarget: Equatable {
    let source: AutoInputSource
    let reason: AutoInputSwitchReason
}
