import Foundation
import MacToolsPluginKit

/// User aliases belong to the host; providers still prepare their original descriptors.
@MainActor
final class CommandPaletteAliasStore {
    enum Failure: Error, Equatable {
        case invalid, unavailable
        case conflict(String)
    }
    private static let key = "commandPalette.actionInputAliases.v1"
    private let defaults: UserDefaults
    private(set) var overrides: [String: String]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        overrides = (defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:])
            .filter { Self.isValid($0.value) }
    }

    static func isValid(_ alias: String) -> Bool {
        alias.count <= 64 && CommandPaletteAliasResolver.isValid(alias)
    }

    func aliases(for item: ActionInputItem) -> [String] {
        guard !item.descriptor.aliases.isEmpty else { return [] }
        return overrides[item.id.id].map { [$0] } ?? item.descriptor.aliases
    }

    func set(_ alias: String?, for item: ActionInputItem, items: [ActionInputItem]) throws {
        guard items.contains(item), !item.descriptor.aliases.isEmpty else { throw Failure.unavailable }
        if let alias, !Self.isValid(alias) { throw Failure.invalid }
        let candidates = alias.map { [$0] } ?? item.descriptor.aliases
        for other in items where other.id != item.id {
            if candidates.contains(where: { candidate in
                aliases(for: other).contains { CommandPaletteAliasResolver.overlaps(candidate, $0) }
            }) { throw Failure.conflict(other.definition.title) }
        }
        overrides[item.id.id] = alias
        defaults.set(overrides, forKey: Self.key)
    }
}
