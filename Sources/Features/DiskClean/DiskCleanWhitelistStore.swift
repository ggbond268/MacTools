import Darwin
import Foundation

struct DiskCleanWhitelistRule: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case defaultRule
        case custom
    }

    let rawPattern: String
    let expandedPattern: String
    let source: Source

    var id: String { expandedPattern }
}

enum DiskCleanWhitelistValidationError: Error, Equatable, Sendable {
    case empty
    case relativePath
    case traversal
    case controlCharacters
    case protectedSystemRoot
}

struct DiskCleanWhitelistStore: Sendable {
    static let finderMetadataSentinel = "FINDER_METADATA"

    static let defaultRulePatterns: [String] = [
        "$HOME/Library/Caches/ms-playwright*",
        "$HOME/.cache/huggingface*",
        "$HOME/.m2/repository/*",
        "$HOME/.gradle/caches/*",
        "$HOME/.gradle/daemon/*",
        "$HOME/.ollama/models/*",
        "$HOME/Library/Caches/com.nssurge.surge-mac/*",
        "$HOME/Library/Application Support/com.nssurge.surge-mac/*",
        "$HOME/Library/Caches/org.R-project.R/R/renv/*",
        "$HOME/Library/Caches/pypoetry/virtualenvs*",
        "$HOME/Library/Caches/JetBrains*",
        "$HOME/Library/Caches/com.jetbrains.toolbox*",
        "$HOME/Library/Caches/tealdeer/tldr-pages",
        "$HOME/Library/Application Support/JetBrains*",
        "$HOME/Library/Caches/com.apple.finder",
        "$HOME/Library/Mobile Documents*",
        "$HOME/Library/Caches/com.apple.FontRegistry*",
        "$HOME/Library/Caches/com.apple.spotlight*",
        "$HOME/Library/Caches/com.apple.Spotlight*",
        "$HOME/Library/Caches/CloudKit*",
        finderMetadataSentinel
    ]

    let homeDirectory: String

    private let includeDefaults: Bool
    private let customRules: [String]

    init(
        homeDirectory: String = NSHomeDirectory(),
        includeDefaults: Bool = true,
        customRules: [String] = []
    ) {
        self.homeDirectory = Self.normalizeSlashes(homeDirectory)
        self.includeDefaults = includeDefaults
        self.customRules = customRules
    }

    func expandedRules() -> [DiskCleanWhitelistRule] {
        let defaultRules = includeDefaults ? Self.defaultRulePatterns : []
        var seenPatterns = Set<String>()
        var rules: [DiskCleanWhitelistRule] = []

        for rawPattern in defaultRules {
            guard let rule = try? makeRule(rawPattern, source: .defaultRule, validate: true) else {
                continue
            }
            append(rule, to: &rules, seenPatterns: &seenPatterns)
        }

        for rawPattern in customRules {
            guard let rule = try? makeRule(rawPattern, source: .custom, validate: true) else {
                continue
            }
            append(rule, to: &rules, seenPatterns: &seenPatterns)
        }

        return rules
    }

    func validateCustomRule(_ rawPattern: String) throws -> DiskCleanWhitelistRule {
        try makeRule(rawPattern, source: .custom, validate: true)
    }

    func matchingRule(for path: String) -> DiskCleanWhitelistRule? {
        let normalizedPath = Self.normalizeSlashes(Self.stripTrailingSlash(expandHome(in: path)))
        guard !normalizedPath.isEmpty else { return nil }

        for rule in expandedRules() {
            let pattern = Self.normalizeSlashes(Self.stripTrailingSlash(rule.expandedPattern))

            if pattern == Self.finderMetadataSentinel {
                if URL(fileURLWithPath: normalizedPath).lastPathComponent == ".DS_Store" {
                    return rule
                }
                continue
            }

            let hasGlob = Self.containsGlob(pattern)
            if normalizedPath == pattern || Self.fnmatch(pattern: pattern, path: normalizedPath) {
                return rule
            }

            if pattern.hasPrefix(normalizedPath + "/") {
                return rule
            }

            if !hasGlob && normalizedPath.hasPrefix(pattern + "/") {
                return rule
            }
        }

        return nil
    }

    func isWhitelisted(_ path: String) -> Bool {
        matchingRule(for: path) != nil
    }

    private func makeRule(
        _ rawPattern: String,
        source: DiskCleanWhitelistRule.Source,
        validate: Bool
    ) throws -> DiskCleanWhitelistRule {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DiskCleanWhitelistValidationError.empty
        }

        guard !Self.containsControlCharacter(trimmed) else {
            throw DiskCleanWhitelistValidationError.controlCharacters
        }

        if trimmed == Self.finderMetadataSentinel {
            return DiskCleanWhitelistRule(
                rawPattern: trimmed,
                expandedPattern: trimmed,
                source: source
            )
        }

        let expanded = Self.normalizeSlashes(Self.stripTrailingSlash(expandHome(in: trimmed)))

        guard expanded.hasPrefix("/") else {
            throw DiskCleanWhitelistValidationError.relativePath
        }

        guard !Self.containsTraversalComponent(expanded) else {
            throw DiskCleanWhitelistValidationError.traversal
        }

        if validate, Self.isProtectedSystemRoot(expanded) {
            throw DiskCleanWhitelistValidationError.protectedSystemRoot
        }

        return DiskCleanWhitelistRule(
            rawPattern: trimmed,
            expandedPattern: expanded,
            source: source
        )
    }

    private func expandHome(in pattern: String) -> String {
        if pattern == "~" || pattern == "$HOME" || pattern == "${HOME}" {
            return homeDirectory
        }
        if pattern.hasPrefix("~/") {
            return homeDirectory + String(pattern.dropFirst())
        }
        if pattern.hasPrefix("$HOME/") {
            return homeDirectory + String(pattern.dropFirst("$HOME".count))
        }
        if pattern.hasPrefix("${HOME}/") {
            return homeDirectory + String(pattern.dropFirst("${HOME}".count))
        }
        return pattern
    }

    private func append(
        _ rule: DiskCleanWhitelistRule,
        to rules: inout [DiskCleanWhitelistRule],
        seenPatterns: inout Set<String>
    ) {
        guard seenPatterns.insert(rule.expandedPattern).inserted else {
            return
        }
        rules.append(rule)
    }

    private static func normalizeSlashes(_ path: String) -> String {
        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        return normalized
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return String(path.dropLast(path.hasSuffix("/") ? 1 : 0))
    }

    private static func containsControlCharacter(_ pattern: String) -> Bool {
        pattern.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar.value == 127
        }
    }

    private static func containsTraversalComponent(_ pattern: String) -> Bool {
        pattern.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func containsGlob(_ pattern: String) -> Bool {
        pattern.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[")) != nil
    }

    private static func fnmatch(pattern: String, path: String) -> Bool {
        pattern.withCString { patternPointer in
            path.withCString { pathPointer in
                Darwin.fnmatch(patternPointer, pathPointer, 0) == 0
            }
        }
    }

    private static func isProtectedSystemRoot(_ pattern: String) -> Bool {
        let path = stripTrailingGlob(from: stripTrailingSlash(pattern))
        if path == "/" {
            return true
        }

        let protectedRoots = [
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/etc",
            "/private",
            "/var",
            "/Library"
        ]

        return protectedRoots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static func stripTrailingGlob(from pattern: String) -> String {
        guard let globRange = pattern.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[")) else {
            return pattern
        }
        return stripTrailingSlash(String(pattern[..<globRange.lowerBound]))
    }
}
