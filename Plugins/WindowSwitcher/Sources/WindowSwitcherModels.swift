import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacToolsPluginKit

enum WindowSwitcherConstants {
    static let pluginID = "window-switcher"
    static let shortcutDefinitionID = "switcher"
    static let shortcutActionID = "switch"
    static let accessibilityPermissionID = "accessibility"
}

enum WindowSwitcherMode: String, Codable, CaseIterable, Identifiable {
    case keyWindow
    case directCycle

    var id: String { rawValue }
}

enum WindowSwitcherSortMode: String, Codable, CaseIterable, Identifiable {
    case recentUse
    case fixed

    var id: String { rawValue }
}

struct WindowSwitcherConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var mode: WindowSwitcherMode
    var sortMode: WindowSwitcherSortMode

    init(
        isEnabled: Bool,
        mode: WindowSwitcherMode,
        sortMode: WindowSwitcherSortMode
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.sortMode = sortMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.mode = try container.decodeIfPresent(WindowSwitcherMode.self, forKey: .mode) ?? .keyWindow
        self.sortMode = try container.decodeIfPresent(WindowSwitcherSortMode.self, forKey: .sortMode) ?? .recentUse
    }

    static let `default` = WindowSwitcherConfiguration(
        isEnabled: true,
        mode: .keyWindow,
        sortMode: .recentUse
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case mode
        case sortMode
    }
}

struct WindowSwitcherShortcutBindingState: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var manual: [String: String]
    var automatic: [String: String]

    init(
        version: Int = currentVersion,
        manual: [String: String] = [:],
        automatic: [String: String] = [:]
    ) {
        self.version = version
        self.manual = manual
        self.automatic = automatic
    }
}

enum WindowSwitcherShortcutCustomizationResult {
    case updated([WindowSwitcherAppEntry])
    case conflict
    case unavailable
}

@MainActor
final class WindowSwitcherStore: ObservableObject {
    private enum Keys {
        static let configuration = "configuration"
        static let shortcutBindings = "shortcut-bindings"
        static let obsoleteShortcutAssignments = "shortcut-assignments"
    }

    @Published private(set) var configuration: WindowSwitcherConfiguration
    @Published private(set) var shortcutBindings: WindowSwitcherShortcutBindingState

    private let storage: PluginStorage
    private let processIsRunning: (pid_t) -> Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        storage: PluginStorage,
        processIsRunning: @escaping (pid_t) -> Bool = {
            NSRunningApplication(processIdentifier: $0)?.isTerminated == false
        }
    ) {
        self.storage = storage
        self.processIsRunning = processIsRunning
        if let data = storage.data(forKey: Keys.configuration),
           let loaded = try? decoder.decode(WindowSwitcherConfiguration.self, from: data) {
            self.configuration = loaded
        } else {
            self.configuration = .default
        }

        if let data = storage.data(forKey: Keys.shortcutBindings),
           let loaded = try? decoder.decode(WindowSwitcherShortcutBindingState.self, from: data) {
            self.shortcutBindings = loaded
        } else {
            self.shortcutBindings = WindowSwitcherShortcutBindingState()
        }
        storage.removeObject(forKey: Keys.obsoleteShortcutAssignments)
    }

    func setMode(_ mode: WindowSwitcherMode) {
        guard configuration.mode != mode else {
            return
        }

        configuration.mode = mode
        persist()
    }

    func setSortMode(_ sortMode: WindowSwitcherSortMode) {
        guard configuration.sortMode != sortMode else {
            return
        }

        configuration.sortMode = sortMode
        persist()
    }

    func setEnabled(_ isEnabled: Bool) {
        guard configuration.isEnabled != isEnabled else {
            return
        }

        configuration.isEnabled = isEnabled
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(configuration) else {
            return
        }

        storage.set(data, forKey: Keys.configuration)
    }

    func assignShortcuts(to entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        removeExpiredWindowBindings(for: entries)
        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: shortcutBindings
        )

        if result.bindingState != shortcutBindings {
            shortcutBindings = result.bindingState
            persistShortcutBindings()
        }

        return result.entries
    }

    func setManualShortcut(
        _ rawToken: String?,
        for entryID: String,
        in entries: [WindowSwitcherAppEntry]
    ) -> WindowSwitcherShortcutCustomizationResult {
        removeExpiredWindowBindings(for: entries)
        let identities = WindowSwitcherShortcutAssignment.identities(for: entries)
        guard let targetIndex = entries.firstIndex(where: { $0.id == entryID }),
              identities.indices.contains(targetIndex)
        else {
            return .unavailable
        }

        let targetIdentity = identities[targetIndex]
        let current = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: shortcutBindings
        )
        var updatedState = current.bindingState

        if let rawToken {
            guard let token = WindowSwitcherShortcutAssignment.normalizedManualToken(rawToken) else {
                return .unavailable
            }

            guard !hasShortcutConflict(
                token,
                targetIdentity: targetIdentity,
                identities: identities,
                current: current
            ) else {
                return .conflict
            }

            updatedState.manual[targetIdentity] = token
        } else {
            updatedState.manual.removeValue(forKey: targetIdentity)
        }

        let updated = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: updatedState
        )
        if updated.bindingState != shortcutBindings {
            shortcutBindings = updated.bindingState
            persistShortcutBindings()
        }
        return .updated(updated.entries)
    }

    func hasShortcutConflict(
        _ rawToken: String,
        for entryID: String,
        in entries: [WindowSwitcherAppEntry]
    ) -> Bool {
        removeExpiredWindowBindings(for: entries)
        guard let token = WindowSwitcherShortcutAssignment.normalizedManualToken(rawToken) else {
            return true
        }

        let identities = WindowSwitcherShortcutAssignment.identities(for: entries)
        guard let targetIndex = entries.firstIndex(where: { $0.id == entryID }),
              identities.indices.contains(targetIndex)
        else {
            return true
        }

        let current = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: shortcutBindings
        )
        return hasShortcutConflict(
            token,
            targetIdentity: identities[targetIndex],
            identities: identities,
            current: current
        )
    }

    private func hasShortcutConflict(
        _ token: String,
        targetIdentity: String,
        identities: [String],
        current: WindowSwitcherShortcutAssignment.Result
    ) -> Bool {
        let activeIdentities = Set(identities)
        let conflictsWithSavedManualBinding = current.bindingState.manual.contains {
            identity, assignedToken in
            identity != targetIdentity
                && !WindowSwitcherShortcutAssignment.isUnresolvedLegacyIdentity(
                    identity,
                    activeIdentities: activeIdentities
                )
                && WindowSwitcherShortcutAssignment.normalizedManualToken(assignedToken) == token
        }
        let conflictsWithRunningEntry = current.entries.enumerated().contains { index, entry in
            identities[index] != targetIdentity && entry.shortcutToken == token
        }
        return conflictsWithSavedManualBinding || conflictsWithRunningEntry
    }

    private func persistShortcutBindings() {
        guard let data = try? encoder.encode(shortcutBindings) else {
            return
        }

        storage.set(data, forKey: Keys.shortcutBindings)
    }

    private func removeExpiredWindowBindings(for entries: [WindowSwitcherAppEntry]) {
        let activeProcessIdentifiers = Set(entries.compactMap { entry in
            entry.isWindowEntry ? entry.processIdentifier : nil
        })
        let previousState = shortcutBindings

        shortcutBindings.manual = shortcutBindings.manual.filter { identity, _ in
            !isExpiredWindowIdentity(identity, activeProcessIdentifiers: activeProcessIdentifiers)
        }
        shortcutBindings.automatic = shortcutBindings.automatic.filter { identity, _ in
            !isExpiredWindowIdentity(identity, activeProcessIdentifiers: activeProcessIdentifiers)
        }

        if shortcutBindings != previousState {
            persistShortcutBindings()
        }
    }

    private func isExpiredWindowIdentity(
        _ identity: String,
        activeProcessIdentifiers: Set<pid_t>
    ) -> Bool {
        let components = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 4,
              components[0] == "window",
              let processIdentifier = pid_t(components[1]),
              !activeProcessIdentifiers.contains(processIdentifier)
        else {
            return false
        }

        return !processIsRunning(processIdentifier)
    }
}

struct WindowSwitcherAppEntry: Identifiable {
    let id: String
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let appName: String
    let windowTitle: String?
    let icon: NSImage?
    let windowElement: AXUIElement?
    let isMinimized: Bool
    let windowNumber: CGWindowID?
    let windowBounds: CGRect?
    let applicationLaunchDate: Date?
    var shortcutToken: String?

    init(
        id: String,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        appName: String,
        windowTitle: String?,
        icon: NSImage?,
        windowElement: AXUIElement?,
        isMinimized: Bool,
        windowNumber: CGWindowID?,
        windowBounds: CGRect?,
        applicationLaunchDate: Date? = nil,
        shortcutToken: String?
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.icon = icon
        self.windowElement = windowElement
        self.isMinimized = isMinimized
        self.windowNumber = windowNumber
        self.windowBounds = windowBounds
        self.applicationLaunchDate = applicationLaunchDate
        self.shortcutToken = shortcutToken
    }

    var displayName: String {
        guard let title = cleanWindowTitle else {
            return appName
        }

        return title
    }

    var displaySubtitle: String? {
        guard let title = cleanWindowTitle,
              title.caseInsensitiveCompare(appName) != .orderedSame
        else {
            return nil
        }

        return appName
    }

    var shortcutDisplay: String? {
        shortcutToken.flatMap(WindowSwitcherSelectionShortcut.init(storageValue:))?.displayValue
    }

    var isWindowEntry: Bool {
        windowElement != nil || windowNumber != nil
    }

    var appIdentifier: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(processIdentifier)"
    }

    private var cleanWindowTitle: String? {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else {
            return nil
        }

        return title
    }
}

struct WindowSwitcherSelectionShortcut: Equatable {
    private static let commandPrefix = "cmd+"

    let key: String
    let usesCommand: Bool

    init?(key: String, usesCommand: Bool) {
        let normalizedKey = key.lowercased()
        guard Self.isAllowedKey(normalizedKey) else {
            return nil
        }

        self.key = normalizedKey
        self.usesCommand = usesCommand
    }

    init?(storageValue: String) {
        let normalized = storageValue.lowercased()
        let usesCommand = normalized.hasPrefix(Self.commandPrefix)
        let key = usesCommand
            ? String(normalized.dropFirst(Self.commandPrefix.count))
            : normalized
        self.init(key: key, usesCommand: usesCommand)
    }

    var storageValue: String {
        usesCommand ? Self.commandPrefix + key : key
    }

    var displayValue: String {
        (usesCommand ? "⌘" : "") + key.uppercased()
    }

    private static func isAllowedKey(_ key: String) -> Bool {
        guard key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first
        else {
            return false
        }

        return (scalar.value >= 97 && scalar.value <= 122)
            || (scalar.value >= 48 && scalar.value <= 57)
    }
}

extension WindowSwitcherAppEntry: Equatable {
    static func == (lhs: WindowSwitcherAppEntry, rhs: WindowSwitcherAppEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.displaySubtitle == rhs.displaySubtitle
            && lhs.shortcutToken == rhs.shortcutToken
    }
}

enum WindowSwitcherShortcutAssignment {
    struct Result {
        let entries: [WindowSwitcherAppEntry]
        let bindingState: WindowSwitcherShortcutBindingState
    }

    private struct Target {
        let index: Int
        let identity: String
        let legacyIdentity: String?
        let preferredToken: String?
    }

    static let letterKeyOrder: [String] = [
        "f", "j", "d", "k", "s", "l", "a", "g", "h",
        "e", "i", "r", "u", "w", "o", "q", "p",
        "c", "m", "v", "n", "x", "b", "z", "t", "y",
    ]
    static let digitKeyOrder: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    static let maximumShortcutCount = (letterKeyOrder.count + digitKeyOrder.count) * 2

    static func assignShortcuts(to entries: [WindowSwitcherAppEntry]) -> [WindowSwitcherAppEntry] {
        assignShortcuts(to: entries, bindingState: WindowSwitcherShortcutBindingState()).entries
    }

    static func assignShortcuts(
        to entries: [WindowSwitcherAppEntry],
        bindingState: WindowSwitcherShortcutBindingState
    ) -> Result {
        guard !entries.isEmpty else {
            return Result(entries: [], bindingState: bindingState)
        }

        let targets = assignmentTargets(for: entries)
        let resolvedBindingState = migrateUnambiguousLegacyBindings(
            from: bindingState,
            targets: targets
        )
        let activeIdentities = Set(targets.map(\.identity))
        let reservedManualTokens = Set<String>(resolvedBindingState.manual.compactMap { identity, rawToken in
            guard !isUnresolvedLegacyIdentity(identity, activeIdentities: activeIdentities) else {
                return nil
            }

            return normalizedManualToken(rawToken)
        })
        let availableTokens = shortcutTokens(count: maximumShortcutCount)
        var assignedTokens = Array<String?>(repeating: nil, count: entries.count)
        var activeManualTokens = Set<String>()
        var usedTokens = reservedManualTokens

        for target in targets {
            guard let token = resolvedBindingState.manual[target.identity].flatMap(normalizedManualToken),
                  activeManualTokens.insert(token).inserted
            else {
                continue
            }

            assignedTokens[target.index] = token
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = resolvedBindingState.automatic[target.identity].flatMap(normalizedShortcutToken),
                  !usedTokens.contains(token)
            else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = target.preferredToken,
                  !usedTokens.contains(token)
            else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        for target in targets where assignedTokens[target.index] == nil {
            guard let token = availableTokens.first(where: { !usedTokens.contains($0) }) else {
                continue
            }

            assignedTokens[target.index] = token
            usedTokens.insert(token)
        }

        let assignedEntries = entries.enumerated().map { index, entry in
            var copy = entry
            copy.shortcutToken = assignedTokens[index]
            return copy
        }
        let updatedState = updatedBindingState(
            from: resolvedBindingState,
            targets: targets,
            assignedTokens: assignedTokens
        )
        return Result(entries: assignedEntries, bindingState: updatedState)
    }

    static func shortcutTokens(count: Int) -> [String] {
        guard count > 0 else {
            return []
        }

        let plainTokens = letterKeyOrder + digitKeyOrder
        let commandTokens = plainTokens.map { "cmd+\($0)" }
        return Array((plainTokens + commandTokens).prefix(count))
    }

    static func identities(for entries: [WindowSwitcherAppEntry]) -> [String] {
        assignmentTargets(for: entries).map(\.identity)
    }

    static func normalizedManualToken(_ token: String) -> String? {
        WindowSwitcherSelectionShortcut(storageValue: token)?.storageValue
    }

    private static func assignmentTargets(for entries: [WindowSwitcherAppEntry]) -> [Target] {
        var appOccurrences: [String: Int] = [:]
        var axWindowOccurrences: [String: Int] = [:]
        let windowCounts = entries.reduce(into: [String: Int]()) { counts, entry in
            guard entry.isWindowEntry else {
                return
            }

            counts[entry.appIdentifier, default: 0] += 1
        }

        return entries.enumerated().map { index, entry in
            let appIdentifier = entry.appIdentifier
            let ordinalIdentity: String?
            let preferredToken: String?
            if entry.windowElement != nil {
                let occurrence = axWindowOccurrences[appIdentifier, default: 0]
                axWindowOccurrences[appIdentifier] = occurrence + 1
                ordinalIdentity = nil
                preferredToken = occurrence == 0 ? preferredSingleKeyToken(for: entry) : nil
            } else if entry.windowNumber != nil {
                ordinalIdentity = nil
                preferredToken = nil
            } else {
                let occurrence = appOccurrences[appIdentifier, default: 0]
                appOccurrences[appIdentifier] = occurrence + 1
                ordinalIdentity = occurrence == 0
                    ? appIdentifier
                    : "\(appIdentifier)#window:\(occurrence + 1)"
                preferredToken = occurrence == 0 ? preferredSingleKeyToken(for: entry) : nil
            }

            let identity: String
            if let windowNumber = entry.windowNumber {
                identity = "window:\(entry.processIdentifier):cg:\(windowNumber)"
            } else if entry.windowElement != nil {
                identity = "window:\(entry.processIdentifier):ax:\(entry.id)"
            } else {
                identity = ordinalIdentity ?? appIdentifier
            }

            return Target(
                index: index,
                identity: identity,
                legacyIdentity: entry.isWindowEntry && windowCounts[appIdentifier] == 1
                    ? appIdentifier
                    : nil,
                preferredToken: preferredToken
            )
        }
    }

    private static func migrateUnambiguousLegacyBindings(
        from bindingState: WindowSwitcherShortcutBindingState,
        targets: [Target]
    ) -> WindowSwitcherShortcutBindingState {
        var state = bindingState

        for target in targets {
            guard let legacyIdentity = target.legacyIdentity,
                  state.manual[target.identity] == nil,
                  let token = state.manual.removeValue(forKey: legacyIdentity)
            else {
                continue
            }

            state.manual[target.identity] = token
        }

        for target in targets {
            guard let legacyIdentity = target.legacyIdentity,
                  state.automatic[target.identity] == nil,
                  let token = state.automatic.removeValue(forKey: legacyIdentity)
            else {
                continue
            }

            state.automatic[target.identity] = token
        }

        return state
    }

    static func isUnresolvedLegacyIdentity(
        _ identity: String,
        activeIdentities: Set<String>
    ) -> Bool {
        guard !activeIdentities.contains(identity) else {
            return false
        }

        return identity.contains("#window:")
            || identity.hasPrefix("bundle:")
            || identity.hasPrefix("pid:")
    }

    private static func updatedBindingState(
        from bindingState: WindowSwitcherShortcutBindingState,
        targets: [Target],
        assignedTokens: [String?]
    ) -> WindowSwitcherShortcutBindingState {
        var state = bindingState
        state.version = WindowSwitcherShortcutBindingState.currentVersion
        let validManualBindings = state.manual.compactMapValues(normalizedManualToken)
        state.manual = validManualBindings
        let activeTargetIdentities = Set(targets.map(\.identity))
        let effectiveManualBindings = validManualBindings.filter { identity, _ in
            !isUnresolvedLegacyIdentity(identity, activeIdentities: activeTargetIdentities)
        }
        let manualIdentities = Set(effectiveManualBindings.keys)
        let manualTokens = Set(effectiveManualBindings.values)
        var activeTokens = Set<String>()
        var activeIdentities = Set<String>()

        for target in targets {
            guard let token = assignedTokens[target.index]
            else {
                continue
            }

            activeTokens.insert(token)
            guard !manualIdentities.contains(target.identity) else {
                continue
            }

            state.automatic[target.identity] = token
            activeIdentities.insert(target.identity)
        }

        for (identity, rawToken) in state.automatic {
            guard let token = normalizedShortcutToken(rawToken) else {
                state.automatic.removeValue(forKey: identity)
                continue
            }

            if isUnresolvedLegacyIdentity(identity, activeIdentities: activeTargetIdentities) {
                continue
            }

            let conflictsWithManual = !manualIdentities.contains(identity) && manualTokens.contains(token)
            let conflictsWithActive = !activeIdentities.contains(identity)
                && !manualIdentities.contains(identity)
                && activeTokens.contains(token)
            if conflictsWithManual || conflictsWithActive {
                state.automatic.removeValue(forKey: identity)
            }
        }

        guard state.automatic.count > 256 else {
            return state
        }

        let retainedIdentities = activeIdentities.union(manualIdentities)
        let retained = state.automatic.filter { retainedIdentities.contains($0.key) }
        let inactive = state.automatic
            .filter { !retainedIdentities.contains($0.key) }
            .sorted { $0.key < $1.key }
            .prefix(max(0, 256 - retained.count))
        state.automatic = inactive.reduce(into: retained) { result, item in
            result[item.key] = item.value
        }
        return state
    }

    private static func preferredSingleKeyToken(for entry: WindowSwitcherAppEntry) -> String? {
        let candidates = [
            entry.appName,
            entry.bundleIdentifier?.split(separator: ".").last.map(String.init),
            entry.bundleIdentifier,
        ].compactMap { $0 }

        for candidate in candidates {
            if let token = firstASCIIKey(in: candidate) {
                return token
            }
        }

        return nil
    }

    private static func firstASCIIKey(in text: String) -> String? {
        for scalar in text.lowercased().unicodeScalars {
            guard scalar.value >= 97, scalar.value <= 122 else {
                continue
            }

            return String(Character(scalar))
        }

        return nil
    }

    private static func normalizedShortcutToken(_ token: String) -> String? {
        WindowSwitcherSelectionShortcut(storageValue: token)?.storageValue
    }
}

enum WindowSwitcherShortcutBindingStore {
    static let defaultBinding = ShortcutBinding(
        keyCode: UInt16(kVK_Tab),
        modifiers: .command
    )

    private static let defaultsKey = "shortcut.customization.\(itemID)"

    static var itemID: String {
        "\(WindowSwitcherConstants.pluginID).shortcut.\(WindowSwitcherConstants.shortcutDefinitionID)"
    }

    static func resolvedBinding(userDefaults: UserDefaults = .standard) -> ShortcutBinding? {
        guard let data = userDefaults.data(forKey: defaultsKey) else {
            return defaultBinding
        }

        do {
            let customization = try JSONDecoder().decode(ShortcutCustomization.self, from: data)
            return ShortcutStoreResolve.resolve(customization: customization, defaultBinding: defaultBinding)
        } catch {
            return defaultBinding
        }
    }
}

private enum ShortcutStoreResolve {
    static func resolve(customization: ShortcutCustomization, defaultBinding: ShortcutBinding?) -> ShortcutBinding? {
        switch customization {
        case .inheritDefault:
            return defaultBinding
        case let .custom(binding):
            return binding
        case .cleared:
            return nil
        }
    }
}
