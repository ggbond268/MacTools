import Foundation

enum WindowRole: String, Codable, CaseIterable, Sendable {
    case commandPalette = "command-palette"
}

enum WindowPosition: Codable, Equatable, Sendable {
    case defaultAnchor
    case custom(normalizedPoint: CGPoint)

    private enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
    }

    private enum PositionType: String, Codable {
        case defaultAnchor = "default"
        case custom = "custom"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PositionType.self, forKey: .type)
        switch type {
        case .defaultAnchor:
            self = .defaultAnchor
        case .custom:
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            self = .custom(normalizedPoint: CGPoint(x: x, y: y))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultAnchor:
            try container.encode(PositionType.defaultAnchor, forKey: .type)
        case let .custom(normalizedPoint):
            try container.encode(PositionType.custom, forKey: .type)
            try container.encode(Double(normalizedPoint.x), forKey: .x)
            try container.encode(Double(normalizedPoint.y), forKey: .y)
        }
    }
}

@MainActor
final class WindowPositionStore: ObservableObject {
    static let shared = WindowPositionStore()

    private let userDefaults: UserDefaults
    private let keyPrefix = "mactools.window-position."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func key(for role: WindowRole) -> String {
        keyPrefix + role.rawValue
    }

    func position(for role: WindowRole) -> WindowPosition {
        guard let data = userDefaults.data(forKey: key(for: role)),
              let position = try? JSONDecoder().decode(WindowPosition.self, from: data) else {
            return .defaultAnchor
        }
        return position
    }

    func savePosition(_ position: WindowPosition, for role: WindowRole) {
        if position == .defaultAnchor {
            resetPosition(for: role)
            return
        }
        guard let data = try? JSONEncoder().encode(position) else { return }
        userDefaults.set(data, forKey: key(for: role))
    }

    func resetPosition(for role: WindowRole) {
        userDefaults.removeObject(forKey: key(for: role))
    }
}
