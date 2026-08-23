import Foundation

@MainActor
final class AutomationRuleStore {
    static let maximumRuleCount = 256
    static let maximumPayloadByteCount = 1_024 * 1_024

    let definitionStore: AutomationDefinitionStore
    private(set) var loadError: String?

    init(
        userDefaults: UserDefaults = .standard,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.definitionStore = AutomationDefinitionStore(
            userDefaults: userDefaults,
            preferencesBackupChangeReporter: preferencesBackupChangeReporter
        )
    }

    init(definitionStore: AutomationDefinitionStore) {
        self.definitionStore = definitionStore
    }

    func rules(workflowID: UUID? = nil) -> [AutomationRule] {
        let result = definitionStore.load()
        loadError = result.ruleError
        if let workflowID {
            return result.snapshot.rules.filter { $0.workflowID == workflowID }
        }
        return result.snapshot.rules
    }

    func rule(id: UUID) -> AutomationRule? {
        rules().first { $0.id == id }
    }

    func create(workflowID: UUID) -> Result<AutomationRule, AutomationRuleStoreError> {
        var stored = rules()
        guard loadError == nil else {
            return .failure(.recoveryRequired)
        }
        guard stored.count < Self.maximumRuleCount else {
            return .failure(.maximumRuleCountReached)
        }
        let rule = AutomationRule(workflowID: workflowID)
        stored.append(rule)
        guard replace(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(rule)
    }

    func upsert(_ rule: AutomationRule) -> Result<AutomationRule, AutomationRuleStoreError> {
        if let failure = Self.validationFailure(rule) {
            return .failure(.invalidRule(failure))
        }
        var stored = rules()
        guard loadError == nil else {
            return .failure(.recoveryRequired)
        }
        var updated = rule
        updated.updatedAt = .now
        if let index = stored.firstIndex(where: { $0.id == rule.id }) {
            stored[index] = updated
        } else {
            guard stored.count < Self.maximumRuleCount else {
                return .failure(.maximumRuleCountReached)
            }
            stored.append(updated)
        }
        guard replace(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(updated)
    }

    func duplicate(id: UUID) -> Result<AutomationRule, AutomationRuleStoreError> {
        let stored = rules()
        guard loadError == nil else {
            return .failure(.recoveryRequired)
        }
        guard let source = stored.first(where: { $0.id == id }) else {
            return .failure(.ruleNotFound)
        }
        let copy = AutomationRule(
            name: byteLimited(source.name + FeatureL10n.string(" 副本")),
            workflowID: source.workflowID,
            isEnabled: source.isEnabled,
            trigger: source.trigger,
            conditions: source.conditions
        )
        return upsert(copy)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        var stored = rules()
        guard loadError == nil else { return false }
        let oldCount = stored.count
        stored.removeAll { $0.id == id }
        return stored.count != oldCount && replace(stored)
    }

    @discardableResult
    func replace(_ rules: [AutomationRule]) -> Bool {
        guard Self.validationFailure(rules) == nil else {
            return false
        }
        return definitionStore.replaceRules(rules)
    }

    static func validationFailure(_ rules: [AutomationRule]) -> String? {
        guard rules.count <= Self.maximumRuleCount,
              Set(rules.map(\.id)).count == rules.count else {
            return "rule-count-or-id"
        }
        return rules.lazy.compactMap(validationFailure).first
    }

    private static func validationFailure(_ rule: AutomationRule) -> String? {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.formatVersion == AutomationRule.currentFormatVersion,
              !name.isEmpty,
              rule.name.utf8.count <= AutomationRule.maximumNameByteCount,
              rule.conditions.count <= AutomationRule.maximumConditionCount,
              Set(rule.conditions.map(\.id)).count == rule.conditions.count,
              validate(rule.trigger),
              rule.conditions.allSatisfy(validate) else {
            return "rule-fields"
        }
        return nil
    }

    private static func validate(_ trigger: AutomationTrigger) -> Bool {
        switch trigger {
        case let .schedule(value):
            validTime(hour: value.hour, minute: value.minute)
                && validWeekdays(value.weekdays)
        case let .calendar(value):
            (-1_440 ... 1_440).contains(value.offsetMinutes)
                && (value.titleContains?.utf8.count ?? 0) <= 256
                && (value.calendarIdentifier?.utf8.count ?? 0) <= 512
        case let .application(value):
            !value.bundleIdentifier.isEmpty && value.bundleIdentifier.utf8.count <= 512
        case let .power(value):
            (0 ... 100).contains(value.batteryLevel)
        case let .display(value):
            (value.displayIdentifier?.utf8.count ?? 0) <= 512
                && (value.displayNameContains?.utf8.count ?? 0) <= 256
        case .network:
            true
        }
    }

    private static func validate(_ condition: AutomationCondition) -> Bool {
        switch condition {
        case let .frontmostApplication(value):
            !value.bundleIdentifier.isEmpty && value.bundleIdentifier.utf8.count <= 512
        case let .power(value):
            validBatteryLevel(value.minimumBatteryLevel)
                && validBatteryLevel(value.maximumBatteryLevel)
                && (value.minimumBatteryLevel ?? 0) <= (value.maximumBatteryLevel ?? 100)
        case let .connectedDisplay(value):
            (value.displayIdentifier?.utf8.count ?? 0) <= 512
                && (value.displayNameContains?.utf8.count ?? 0) <= 256
        case let .timeRange(value):
            (0 ... 1_439).contains(value.startMinute)
                && (0 ... 1_439).contains(value.endMinute)
                && validWeekdays(value.weekdays)
        case .network:
            true
        }
    }

    private static func validTime(hour: Int, minute: Int) -> Bool {
        (0 ... 23).contains(hour) && (0 ... 59).contains(minute)
    }

    private static func validWeekdays(_ weekdays: [Int]) -> Bool {
        !weekdays.isEmpty
            && weekdays.count == Set(weekdays).count
            && weekdays.allSatisfy { (1 ... 7).contains($0) }
    }

    private static func validBatteryLevel(_ level: Int?) -> Bool {
        level.map { (0 ... 100).contains($0) } ?? true
    }

    private func byteLimited(_ value: String) -> String {
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= AutomationRule.maximumNameByteCount else {
                break
            }
            result = candidate
        }
        return result
    }
}
