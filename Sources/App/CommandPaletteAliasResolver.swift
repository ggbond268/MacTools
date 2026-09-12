import Foundation

struct CommandPaletteAliasMatch {
    let item: ActionInputItem
    let message: String?
    let isAmbiguous: Bool
}

struct CommandPaletteAliasResolver {
    let items: [ActionInputItem]
    var overrides: [String: String] = [:]

    func resolve(_ query: String) -> CommandPaletteAliasMatch? {
        let bindings = items.filter { !$0.descriptor.aliases.isEmpty }.flatMap { item in
            (overrides[item.id.id].map { [$0] } ?? item.descriptor.aliases).filter(Self.isValid).map { (alias: $0, item: item) }
        }
        for binding in bindings {
            guard let range = query.range(of: binding.alias, options: [.anchored, .caseInsensitive]),
                  range.upperBound == query.endIndex || query[range.upperBound] == " " else { continue }
            let ambiguous = bindings.contains { other in
                other.item.id != binding.item.id && Self.overlaps(binding.alias, other.alias)
            }
            let message = range.upperBound == query.endIndex ? nil : String(query[query.index(after: range.upperBound)...])
            return CommandPaletteAliasMatch(item: binding.item, message: message, isAmbiguous: ambiguous)
        }
        return nil
    }

    static func isValid(_ alias: String) -> Bool {
        !alias.isEmpty && alias == alias.trimmingCharacters(in: .whitespacesAndNewlines)
            && !alias.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func overlaps(_ a: String, _ b: String) -> Bool {
        func prefix(_ a: String, _ b: String) -> Bool {
            guard let range = b.range(of: a, options: [.anchored, .caseInsensitive]) else { return false }
            return range.upperBound == b.endIndex || b[range.upperBound] == " "
        }
        return prefix(a, b) || prefix(b, a)
    }
}
