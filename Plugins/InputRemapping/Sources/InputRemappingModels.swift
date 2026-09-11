import Combine
import CoreGraphics
import Foundation
import MacToolsPluginKit
import OSLog

enum InputRemappingRulePolicy {
    /// CoreGraphics numbers the primary button as 0; all physical buttons through 32 are supported.
    static let minimumButtonNumber: Int64 = 0
    static let maximumButtonNumber: Int64 = 32
    static let eligibleButtonNumbers = minimumButtonNumber...maximumButtonNumber
    static let longPressDuration: TimeInterval = 0.45
    static let doubleClickInterval: TimeInterval = 0.35
    private static let timingTolerance: TimeInterval = 0.000_001

    static func isEligible(buttonNumber: Int64) -> Bool {
        eligibleButtonNumbers.contains(buttonNumber)
    }
    static func normalized(buttonNumber: Int64) -> Int64 {
        min(maximumButtonNumber, max(minimumButtonNumber, buttonNumber))
    }
    static func reachesLongPressDuration(_ duration: TimeInterval) -> Bool {
        duration >= longPressDuration - timingTolerance
    }
}

enum InputRemappingMouseInteraction: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case click
    case doubleClick
    case longPress
}

enum InputRemappingScrollDirection: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case up
    case down
    case left
    case right
}

enum InputRemappingOutputConfigurationState: String, Codable, Equatable, Sendable {
    case needsSelection
    case recordingShortcut
    case recordingKeyTap
    case configured
}

enum InputRemappingTrigger: Codable, Equatable, Hashable, Sendable {
    case keyboard(keyCode: UInt16, modifiers: ShortcutModifiers)
    case mouseButton(number: Int64, modifiers: ShortcutModifiers, interaction: InputRemappingMouseInteraction)
    case scroll(direction: InputRemappingScrollDirection, modifiers: ShortcutModifiers)
    case trackpadGesture(TrackpadGesture)

    private enum CodingKeys: String, CodingKey {
        case kind, keyCode, number, modifiers, interaction, direction, gesture
    }

    private enum Kind: String, Codable {
        case keyboard, mouseButton, scroll, trackpadGesture
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .keyboard:
            self = .keyboard(
                keyCode: try c.decode(UInt16.self, forKey: .keyCode),
                modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers)
            )
        case .mouseButton:
            self = .mouseButton(
                number: InputRemappingRulePolicy.normalized(buttonNumber: try c.decode(Int64.self, forKey: .number)),
                modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers),
                interaction: try c.decode(InputRemappingMouseInteraction.self, forKey: .interaction)
            )
        case .scroll:
            self = .scroll(
                direction: try c.decode(InputRemappingScrollDirection.self, forKey: .direction),
                modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers)
            )
        case .trackpadGesture:
            self = .trackpadGesture(try c.decode(TrackpadGesture.self, forKey: .gesture))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .keyboard(keyCode, modifiers):
            try c.encode(Kind.keyboard, forKey: .kind)
            try c.encode(keyCode, forKey: .keyCode)
            try c.encode(modifiers, forKey: .modifiers)
        case let .mouseButton(number, modifiers, interaction):
            try c.encode(Kind.mouseButton, forKey: .kind)
            try c.encode(number, forKey: .number)
            try c.encode(modifiers, forKey: .modifiers)
            try c.encode(interaction, forKey: .interaction)
        case let .scroll(direction, modifiers):
            try c.encode(Kind.scroll, forKey: .kind)
            try c.encode(direction, forKey: .direction)
            try c.encode(modifiers, forKey: .modifiers)
        case let .trackpadGesture(gesture):
            try c.encode(Kind.trackpadGesture, forKey: .kind)
            try c.encode(gesture, forKey: .gesture)
        }
    }

    var modifiers: ShortcutModifiers {
        switch self {
        case let .keyboard(_, modifiers), let .mouseButton(_, modifiers, _), let .scroll(_, modifiers):
            modifiers
        case .trackpadGesture:
            []
        }
    }

    func normalized() -> Self {
        guard case let .mouseButton(number, modifiers, interaction) = self else { return self }
        return .mouseButton(number: InputRemappingRulePolicy.normalized(buttonNumber: number), modifiers: modifiers, interaction: interaction)
    }
}

enum InputRemappingCapturedInput: Equatable, Sendable {
    case keyboard(keyCode: UInt16, modifiers: ShortcutModifiers)
    case mouseButton(number: Int64, modifiers: ShortcutModifiers)
    case scroll(direction: InputRemappingScrollDirection, modifiers: ShortcutModifiers)

    func trigger(interaction: InputRemappingMouseInteraction = .click) -> InputRemappingTrigger {
        switch self {
        case let .keyboard(keyCode, modifiers):
            .keyboard(keyCode: keyCode, modifiers: modifiers)
        case let .mouseButton(number, modifiers):
            .mouseButton(number: number, modifiers: modifiers, interaction: interaction)
        case let .scroll(direction, modifiers):
            .scroll(direction: direction, modifiers: modifiers)
        }
    }
}

struct InputRemappingRule: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, trigger, buttonNumber, modifiers, action
        case isInputConfigured, isOutputConfigured, outputConfigurationState
        case isUnsafeTriggerConfirmed, isUnmodifiedKeyboardConfirmed
    }

    enum Action: Codable, Equatable, Hashable, Sendable, CaseIterable {
        case shortcut(ShortcutBinding)
        case keyTap(KeyboardKeyTap?)
        case mouseBack, mouseForward, mouseMiddle, missionControl, spaceLeft, spaceRight
        case mediaPlayPause, volumeDown, volumeUp

        static var allCases: [Action] {
            [
                .shortcut(ShortcutBinding(keyCode: 0, modifiers: [.command])),
                .keyTap(nil),
                .mouseBack, .mouseForward, .mouseMiddle, .missionControl,
                .spaceLeft, .spaceRight, .mediaPlayPause, .volumeDown, .volumeUp,
            ]
        }

        enum Kind: CaseIterable, Hashable {
            case shortcut, keyTap, mouseBack, mouseForward, mouseMiddle, missionControl, spaceLeft, spaceRight, mediaPlayPause, volumeDown, volumeUp
        }

        var kind: Kind {
            switch self {
            case .shortcut: .shortcut
            case .keyTap: .keyTap
            case .mouseBack: Kind.mouseBack
            case .mouseForward: Kind.mouseForward
            case .mouseMiddle: Kind.mouseMiddle
            case .missionControl: Kind.missionControl
            case .spaceLeft: Kind.spaceLeft
            case .spaceRight: Kind.spaceRight
            case .mediaPlayPause: Kind.mediaPlayPause
            case .volumeDown: Kind.volumeDown
            case .volumeUp: Kind.volumeUp
            }
        }

        func replacingKind(_ kind: Kind) -> Action {
            switch kind {
            case .shortcut:
                if case .shortcut = self {
                    return self
                }
                return .shortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]))
            case .keyTap:
                if case .keyTap = self {
                    return self
                }
                return .keyTap(nil)
            case .mouseBack: return .mouseBack
            case .mouseForward: return .mouseForward
            case .mouseMiddle: return .mouseMiddle
            case .missionControl: return .missionControl
            case .spaceLeft: return .spaceLeft
            case .spaceRight: return .spaceRight
            case .mediaPlayPause: return .mediaPlayPause
            case .volumeDown: return .volumeDown
            case .volumeUp: return .volumeUp
            }
        }

        func kindTitle(localization: PluginLocalization) -> String {
            switch self {
            case .shortcut: localization.string("action.shortcut", defaultValue: "Shortcut")
            case .keyTap: localization.string("action.singleKey", defaultValue: "Single Key")
            default: title(localization: localization)
            }
        }

        static func action(for kind: Kind) -> Action {
            Action.shortcut(ShortcutBinding(keyCode: 0, modifiers: [.command])).replacingKind(kind)
        }

        func title(localization: PluginLocalization) -> String {
            switch self {
            case let .shortcut(binding): localization.format("action.shortcut.format", defaultValue: "快捷键 %@%d", binding.modifiers.symbolString, binding.keyCode)
            case let .keyTap(keyTap): localization.format(
                "action.singleKey.format",
                defaultValue: "单键 %@",
                KeyboardKeyTapFormatter.displayString(for: keyTap)
            )
            case .mouseBack: localization.string("action.mouseBack", defaultValue: "鼠标后退")
            case .mouseForward: localization.string("action.mouseForward", defaultValue: "鼠标前进")
            case .mouseMiddle: localization.string("action.mouseMiddle", defaultValue: "中键点击")
            case .missionControl: localization.string("action.missionControl", defaultValue: "调度中心")
            case .spaceLeft: localization.string("action.spaceLeft", defaultValue: "左侧空间")
            case .spaceRight: localization.string("action.spaceRight", defaultValue: "右侧空间")
            case .mediaPlayPause: localization.string("action.mediaPlayPause", defaultValue: "播放/暂停")
            case .volumeDown: localization.string("action.volumeDown", defaultValue: "降低音量")
            case .volumeUp: localization.string("action.volumeUp", defaultValue: "提高音量")
            }
        }
    }

    let id: UUID
    var isEnabled: Bool
    var trigger: InputRemappingTrigger
    var action: Action
    var isInputConfigured: Bool
    var outputConfigurationState: InputRemappingOutputConfigurationState
    var isUnsafeTriggerConfirmed: Bool

    var isOutputConfigured: Bool {
        get { outputConfigurationState == .configured }
        set { outputConfigurationState = newValue ? .configured : .needsSelection }
    }

    /// The sole gate for an event to be intercepted or a trackpad claim to be active.
    var isRunnable: Bool {
        isEnabled
            && isInputConfigured
            && isOutputConfigured
            && (!Self.requiresExplicitConfirmation(for: trigger) || isUnsafeTriggerConfirmed)
    }

    var requiresEventTap: Bool {
        switch trigger {
        case .keyboard, .mouseButton, .scroll:
            true
        case .trackpadGesture:
            false
        }
    }

    var claimedTrackpadGesture: TrackpadGesture? {
        guard isRunnable,
              case let .trackpadGesture(gesture) = trigger
        else { return nil }
        return gesture
    }

    // Compatibility conveniences for rules saved before universal input support.
    var buttonNumber: Int64 {
        get {
            if case let .mouseButton(number, _, _) = trigger {
                number
            } else {
                InputRemappingRulePolicy.minimumButtonNumber
            }
        }
        set {
            replaceTrigger(.mouseButton(number: newValue, modifiers: modifiers, interaction: mouseInteraction))
        }
    }
    var modifiers: ShortcutModifiers {
        get { trigger.modifiers }
        set {
            switch trigger {
            case let .keyboard(keyCode, _):
                replaceTrigger(.keyboard(keyCode: keyCode, modifiers: newValue))
            case let .mouseButton(number, _, interaction):
                replaceTrigger(.mouseButton(number: number, modifiers: newValue, interaction: interaction))
            case let .scroll(direction, _):
                replaceTrigger(.scroll(direction: direction, modifiers: newValue))
            case .trackpadGesture:
                break
            }
        }
    }
    var mouseInteraction: InputRemappingMouseInteraction {
        get {
            if case let .mouseButton(_, _, interaction) = trigger {
                interaction
            } else {
                .click
            }
        }
        set {
            if case let .mouseButton(number, modifiers, _) = trigger {
                replaceTrigger(.mouseButton(number: number, modifiers: modifiers, interaction: newValue))
            }
        }
    }

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        trigger: InputRemappingTrigger = .mouseButton(number: 3, modifiers: [], interaction: .click),
        action: Action = .mouseBack,
        isInputConfigured: Bool = true,
        outputConfigurationState: InputRemappingOutputConfigurationState = .configured,
        isUnsafeTriggerConfirmed: Bool = false
    ) {
        let hasUsableKeyTap: Bool
        if case let .keyTap(keyTap) = action {
            hasUsableKeyTap = keyTap?.isSupported == true
        } else {
            hasUsableKeyTap = true
        }
        let durableOutputConfigurationState: InputRemappingOutputConfigurationState
        switch outputConfigurationState {
        case .recordingShortcut, .recordingKeyTap:
            durableOutputConfigurationState = .needsSelection
        case .configured where !hasUsableKeyTap:
            durableOutputConfigurationState = .needsSelection
        default:
            durableOutputConfigurationState = outputConfigurationState
        }
        self.id = id
        self.trigger = trigger.normalized()
        self.isUnsafeTriggerConfirmed = isUnsafeTriggerConfirmed
        self.action = action
        self.isInputConfigured = isInputConfigured
        self.outputConfigurationState = durableOutputConfigurationState
        self.isEnabled = isEnabled
            && isInputConfigured
            && durableOutputConfigurationState == .configured
            && (!Self.requiresExplicitConfirmation(for: self.trigger) || isUnsafeTriggerConfirmed)
    }

    init(id: UUID = UUID(), isEnabled: Bool = true, buttonNumber: Int64 = 3, modifiers: ShortcutModifiers = [], action: Action = .mouseBack) {
        self.init(id: id, isEnabled: isEnabled, trigger: .mouseButton(number: buttonNumber, modifiers: modifiers, interaction: .click), action: action)
    }

    static func newDraft() -> InputRemappingRule {
        InputRemappingRule(
            isEnabled: false,
            trigger: .mouseButton(number: InputRemappingRulePolicy.minimumButtonNumber, modifiers: [], interaction: .click),
            action: .shortcut(ShortcutBinding(keyCode: 0, modifiers: [.command])),
            isInputConfigured: false,
            outputConfigurationState: .needsSelection
        )
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let enabled = try c.decode(Bool.self, forKey: .isEnabled)
        let action = try c.decode(Action.self, forKey: .action)
        let isInputConfigured = try c.decodeIfPresent(Bool.self, forKey: .isInputConfigured) ?? true
        let outputConfigurationState = try c.decodeIfPresent(InputRemappingOutputConfigurationState.self, forKey: .outputConfigurationState)
            ?? ((try c.decodeIfPresent(Bool.self, forKey: .isOutputConfigured)) == false ? .needsSelection : .configured)
        let isUnsafeTriggerConfirmed = try c.decodeIfPresent(Bool.self, forKey: .isUnsafeTriggerConfirmed)
            ?? c.decodeIfPresent(Bool.self, forKey: .isUnmodifiedKeyboardConfirmed)
            ?? false
        if let trigger = try c.decodeIfPresent(InputRemappingTrigger.self, forKey: .trigger) {
            self.init(
                id: id,
                isEnabled: enabled,
                trigger: trigger,
                action: action,
                isInputConfigured: isInputConfigured,
                outputConfigurationState: outputConfigurationState,
                isUnsafeTriggerConfirmed: isUnsafeTriggerConfirmed
            )
        } else {
            self.init(
                id: id,
                isEnabled: enabled,
                trigger: .mouseButton(
                    number: try c.decode(Int64.self, forKey: .buttonNumber),
                    modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers),
                    interaction: .click
                ),
                action: action,
                isInputConfigured: isInputConfigured,
                outputConfigurationState: outputConfigurationState,
                isUnsafeTriggerConfirmed: isUnsafeTriggerConfirmed
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(trigger.normalized(), forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encode(isInputConfigured, forKey: .isInputConfigured)
        try c.encode(outputConfigurationState, forKey: .outputConfigurationState)
        try c.encode(isUnsafeTriggerConfirmed, forKey: .isUnsafeTriggerConfirmed)
    }
    func normalized() -> InputRemappingRule {
        InputRemappingRule(
            id: id,
            isEnabled: isEnabled,
            trigger: trigger,
            action: action,
            isInputConfigured: isInputConfigured,
            outputConfigurationState: outputConfigurationState,
            isUnsafeTriggerConfirmed: isUnsafeTriggerConfirmed
        )
    }

    mutating func replaceTrigger(_ newTrigger: InputRemappingTrigger) {
        trigger = newTrigger.normalized()
        isUnsafeTriggerConfirmed = false
        if Self.requiresExplicitConfirmation(for: trigger) {
            isEnabled = false
        }
    }

    static func requiresExplicitConfirmation(for trigger: InputRemappingTrigger) -> Bool {
        switch trigger {
        case let .keyboard(_, modifiers):
            return modifiers.isEmpty
        case let .mouseButton(number, modifiers, interaction):
            return modifiers.isEmpty
                && interaction == .click
                && (number == 0 || number == 1)
        case .scroll, .trackpadGesture:
            return false
        }
    }
    static func modifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.maskShift) {
            result.insert(.shift)
        }
        if flags.contains(.maskControl) {
            result.insert(.control)
        }
        if flags.contains(.maskAlternate) {
            result.insert(.option)
        }
        if flags.contains(.maskCommand) {
            result.insert(.command)
        }
        return result
    }
}

enum InputRemappingRuleMatcher {
    static func rule(for buttonNumber: Int64, flags: CGEventFlags, in rules: [InputRemappingRule], interaction: InputRemappingMouseInteraction = .click) -> InputRemappingRule? {
        rules.first { rule in
            guard rule.isRunnable, case let .mouseButton(number, modifiers, expectedInteraction) = rule.trigger else { return false }
            return number == buttonNumber && modifiers == InputRemappingRule.modifiers(from: flags) && expectedInteraction == interaction
        }
    }
    static func keyboardRule(for keyCode: UInt16, flags: CGEventFlags, in rules: [InputRemappingRule]) -> InputRemappingRule? {
        rules.first { rule in
            guard case let .keyboard(expected, modifiers) = rule.trigger else {
                return false
            }
            return rule.isRunnable
                && expected == keyCode
                && modifiers == InputRemappingRule.modifiers(from: flags)
        }
    }
    static func scrollRule(for direction: InputRemappingScrollDirection, flags: CGEventFlags, in rules: [InputRemappingRule]) -> InputRemappingRule? {
        rules.first { rule in
            guard case let .scroll(expected, modifiers) = rule.trigger else {
                return false
            }
            return rule.isRunnable
                && expected == direction
                && modifiers == InputRemappingRule.modifiers(from: flags)
        }
    }
}

enum InputRemappingMouseEventPhase {
    case down, up
}

struct InputRemappingEventProcessor {
    private struct MouseSequenceState {
        let timestamp: TimeInterval
        let modifiers: ShortcutModifiers
    }

    private var buttonsAwaitingConsumedUp: Set<Int64> = []
    private var pendingDoubleClickActions: [Int64: InputRemappingRule.Action] = [:]
    private var keysAwaitingConsumedUp: Set<UInt16> = []
    private var lastClickState: [Int64: MouseSequenceState] = [:]
    private var mouseDownState: [Int64: MouseSequenceState] = [:]

    mutating func shouldConsume(phase: InputRemappingMouseEventPhase, buttonNumber: Int64, flags: CGEventFlags, isMarkedSynthetic: Bool, rules: [InputRemappingRule], timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime, execute: (InputRemappingRule.Action) -> Bool) -> Bool {
        guard !isMarkedSynthetic else { return false }
        let modifiers = InputRemappingRule.modifiers(from: flags)
        switch phase {
        case .down:
            mouseDownState[buttonNumber] = MouseSequenceState(timestamp: timestamp, modifiers: modifiers)
            if let rule = InputRemappingRuleMatcher.rule(for: buttonNumber, flags: flags, in: rules),
               execute(rule.action) {
                buttonsAwaitingConsumedUp.insert(buttonNumber)
                return true
            }
            if let rule = InputRemappingRuleMatcher.rule(for: buttonNumber, flags: flags, in: rules, interaction: .doubleClick),
               let previous = lastClickState[buttonNumber],
               previous.modifiers == modifiers,
               timestamp - previous.timestamp <= InputRemappingRulePolicy.doubleClickInterval {
                lastClickState[buttonNumber] = nil
                pendingDoubleClickActions[buttonNumber] = rule.action
                return false
            }
            return false
        case .up:
            if buttonsAwaitingConsumedUp.remove(buttonNumber) != nil {
                return true
            }
            if let action = pendingDoubleClickActions.removeValue(forKey: buttonNumber) {
                guard let started = mouseDownState.removeValue(forKey: buttonNumber),
                      started.modifiers == modifiers
                else { return false }
                _ = execute(action)
                return false
            }
            guard let started = mouseDownState.removeValue(forKey: buttonNumber), started.modifiers == modifiers else {
                lastClickState[buttonNumber] = nil
                return false
            }
            lastClickState[buttonNumber] = started
            guard InputRemappingRulePolicy.reachesLongPressDuration(timestamp - started.timestamp),
                  let rule = InputRemappingRuleMatcher.rule(for: buttonNumber, flags: flags, in: rules, interaction: .longPress)
            else { return false }
            // Long presses intentionally pass through. Consuming them would require buffering/replaying the original click.
            _ = execute(rule.action)
            return false
        }
    }

    mutating func shouldConsumeKeyboard(
        isKeyDown: Bool,
        keyCode: UInt16,
        flags: CGEventFlags,
        isMarkedSynthetic: Bool,
        rules: [InputRemappingRule],
        execute: (InputRemappingRule.Action) -> Bool
    ) -> Bool {
        guard !isMarkedSynthetic else { return false }
        guard isKeyDown else { return keysAwaitingConsumedUp.remove(keyCode) != nil }
        guard let rule = InputRemappingRuleMatcher.keyboardRule(
            for: keyCode,
            flags: flags,
            in: rules
        ), execute(rule.action) else {
            return false
        }
        keysAwaitingConsumedUp.insert(keyCode)
        return true
    }

    mutating func reset() {
        buttonsAwaitingConsumedUp.removeAll()
        pendingDoubleClickActions.removeAll()
        keysAwaitingConsumedUp.removeAll()
        lastClickState.removeAll()
        mouseDownState.removeAll()
    }
}

@MainActor
final class InputRemappingStore: ObservableObject {
    @Published private(set) var rules: [InputRemappingRule]
    private static let storageKey = "input-remapping.rules.v1"
    private let storage: any PluginStorage
    private let logger: Logger
    var onRulesChange: (() -> Void)?
    init(
        storage: any PluginStorage,
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
            category: "InputRemappingStore"
        )
    ) {
        self.storage = storage
        self.logger = logger

        guard let data = storage.data(forKey: Self.storageKey) else {
            rules = []
            return
        }

        do {
            rules = try JSONDecoder().decode([InputRemappingRule].self, from: data)
        } catch {
            logger.error("Failed to decode input remapping rules: \(String(describing: error), privacy: .public)")
            rules = []
        }
    }

    func addRule() {
        update(rules + [.newDraft()])
    }

    func delete(_ rule: InputRemappingRule) {
        update(rules.filter { $0.id != rule.id })
    }
    func disableUnsafeTriggers() {
        let updatedRules = rules.map { rule in
            guard InputRemappingRule.requiresExplicitConfirmation(for: rule.trigger) else { return rule }
            var disabledRule = rule
            disabledRule.isEnabled = false
            disabledRule.isUnsafeTriggerConfirmed = false
            return disabledRule
        }
        guard updatedRules != rules else { return }
        update(updatedRules)
    }
    func replace(_ rule: InputRemappingRule) {
        update(rules.map { $0.id == rule.id ? rule : $0 })
    }

    private func update(_ rules: [InputRemappingRule]) {
        let normalizedRules = rules.map { $0.normalized() }
        do {
            storage.set(try JSONEncoder().encode(normalizedRules), forKey: Self.storageKey)
            self.rules = normalizedRules
            onRulesChange?()
        } catch {
            logger.error("Failed to encode input remapping rules: \(String(describing: error), privacy: .public)")
        }
    }
}
