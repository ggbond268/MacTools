import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacToolsPluginKit
import XCTest
@testable import InputRemappingPlugin

@MainActor
private final class InputRemappingMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}

private final class InputRemappingTapSpy: InputRemappingEventTapping {
    private(set) var rules: [InputRemappingRule] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCaptureCallCount = 0
    var startResult = true
    var beginInputResult = true
    var beginShortcutResult = true
    var captureHandler: (@Sendable (InputRemappingCapturedInput) -> Void)?
    var shortcutCaptureHandler: (@Sendable (ShortcutBinding) -> Void)?
    private(set) var executedActions: [InputRemappingRule.Action] = []
    var emergencyStopHandler: (@Sendable () -> Void)?

    var isCaptureSequenceActive: Bool {
        captureHandler != nil || shortcutCaptureHandler != nil
    }

    func update(rules: [InputRemappingRule]) {
        self.rules = rules
    }

    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {
        stopCallCount += 1
    }

    func beginInputCapture(_ handler: @escaping @Sendable (InputRemappingCapturedInput) -> Void) -> Bool {
        captureHandler = handler
        guard beginInputResult else {
            cancelButtonCapture()
            return false
        }
        return true
    }

    func beginShortcutCapture(_ handler: @escaping @Sendable (ShortcutBinding) -> Void) -> Bool {
        shortcutCaptureHandler = handler
        guard beginShortcutResult else {
            cancelButtonCapture()
            return false
        }
        return true
    }

    func cancelButtonCapture() {
        cancelCaptureCallCount += 1
        captureHandler = nil
        shortcutCaptureHandler = nil
    }

    func execute(_ action: InputRemappingRule.Action) -> Bool {
        executedActions.append(action)
        return true
    }

    func capture(_ input: InputRemappingCapturedInput) {
        let handler = captureHandler
        captureHandler = nil
        handler?(input)
    }

    func capture(shortcut: ShortcutBinding) {
        let handler = shortcutCaptureHandler
        shortcutCaptureHandler = nil
        handler?(shortcut)
    }

}

@MainActor
private final class InputRemappingPermissionState {
    var accessibilityGranted = false
    var inputMonitoringStatus: InputRemappingInputMonitoringStatus = .denied
}

private final class InputRemappingLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class InputRemappingModelsTests: XCTestCase {

    func testUnsupportedPersistedSingleKeyIsDisabledWithoutDroppingRule() throws {
        var rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        rule.action = .keyTap(KeyboardKeyTap(keyCode: .max))
        rule.outputConfigurationState = .configured
        rule.isEnabled = true

        let decoded = try JSONDecoder().decode(
            InputRemappingRule.self,
            from: JSONEncoder().encode(rule)
        )

        XCTAssertEqual(decoded.action, .keyTap(KeyboardKeyTap(keyCode: .max)))
        XCTAssertEqual(decoded.outputConfigurationState, .needsSelection)
        XCTAssertFalse(decoded.isEnabled)
    }
    func testMatcherRequiresEligibleButtonAndExactModifiers() {
        let rule = InputRemappingRule(
            buttonNumber: 4,
            modifiers: [.command],
            action: .mouseBack
        )

        XCTAssertEqual(
            InputRemappingRuleMatcher.rule(for: 4, flags: [.maskCommand], in: [rule])?.id,
            rule.id
        )
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 2, flags: [.maskCommand], in: [rule]))
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 33, flags: [.maskCommand], in: [rule]))
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 4, flags: [], in: [rule]))
    }

    func testIncompleteOrUnconfirmedRulesNeverMatch() {
        let incomplete = InputRemappingRule(
            isEnabled: true,
            trigger: .mouseButton(number: 4, modifiers: [], interaction: .click),
            action: .mouseBack,
            isInputConfigured: true,
            outputConfigurationState: .recordingShortcut
        )
        let primaryButton = InputRemappingRule(
            isEnabled: true,
            trigger: .mouseButton(number: 0, modifiers: [], interaction: .click),
            action: .mouseBack
        )

        XCTAssertFalse(incomplete.isEnabled)
        XCTAssertFalse(primaryButton.isEnabled)
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 4, flags: [], in: [incomplete]))
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 0, flags: [], in: [primaryButton]))
    }

    func testSuccessfulDownConsumesMatchingUpWithoutExecutingTwice() {
        let rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        var processor = InputRemappingEventProcessor()
        var executions: [InputRemappingRule.Action] = []

        XCTAssertTrue(processor.shouldConsume(
            phase: .down,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: {
                executions.append($0)
                return true
            }
        ))
        XCTAssertTrue(processor.shouldConsume(
            phase: .up,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in XCTFail("Mouse-up must not execute an action"); return true }
        ))
        XCTAssertEqual(executions, [.mouseBack])
    }

    func testSuccessfulKeyboardDownConsumesMatchingUpWithoutExecutingTwice() {
        let rule = InputRemappingRule(
            trigger: .keyboard(keyCode: 12, modifiers: [.command]),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertTrue(processor.shouldConsumeKeyboard(
            isKeyDown: true,
            keyCode: 12,
            flags: [.maskCommand],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in executions += 1; return true }
        ))
        XCTAssertTrue(processor.shouldConsumeKeyboard(
            isKeyDown: false,
            keyCode: 12,
            flags: [.maskCommand],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in XCTFail("Key-up must not execute an action"); return true }
        ))
        XCTAssertEqual(executions, 1)
    }

    func testUnmodifiedKeyboardTriggerStartsDisabledUntilConfirmed() {
        let rule = InputRemappingRule(
            isEnabled: true,
            trigger: .keyboard(keyCode: 12, modifiers: []),
            action: .mouseBack
        )
        XCTAssertFalse(rule.isEnabled)

        var editedRule = InputRemappingRule(buttonNumber: 4)
        editedRule.replaceTrigger(.keyboard(keyCode: 12, modifiers: []))
        XCTAssertFalse(editedRule.isEnabled)
    }

    func testDoubleClickExecutesWithoutConsumingTheNativeClickPair() {
        let rule = InputRemappingRule(
            trigger: .mouseButton(number: 4, modifiers: [], interaction: .doubleClick),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.01, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.11, execute: { _ in executions += 1; return true }))
        XCTAssertEqual(executions, 1)
    }

    func testLongPressExecutesOnceWithStableModifiers() {
        let rule = InputRemappingRule(
            trigger: .mouseButton(number: 4, modifiers: [.command], interaction: .longPress),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1 + InputRemappingRulePolicy.longPressDuration, execute: { _ in executions += 1; return true }))

        XCTAssertEqual(executions, 1)
    }

    func testEmergencyShortcutCancelsCaptureAndRunsOnlyOncePerPress() {
        let tap = InputRemappingEventTap(captureStartResult: true)
        let counter = InputRemappingLockedCounter()
        tap.emergencyStopHandler = { counter.increment() }
        XCTAssertTrue(tap.beginInputCapture { _ in XCTFail("Emergency shortcut must not be recorded") })
        defer { tap.stop() }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        down.flags = [.maskControl, .maskAlternate, .maskCommand]
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)!

        XCTAssertNil(tap.handle(type: .keyDown, event: down))
        XCTAssertNil(tap.handle(type: .keyDown, event: down))
        XCTAssertTrue(tap.isCaptureSequenceActive)
        XCTAssertNil(tap.handle(type: .keyUp, event: up))
        XCTAssertFalse(tap.isCaptureSequenceActive)
        XCTAssertEqual(counter.count, 1)
    }

    func testScrollRuleMatchesOnlyItsDirectionAndModifiers() {
        let rule = InputRemappingRule(
            trigger: .scroll(direction: .up, modifiers: [.command]),
            action: .mouseBack
        )
        XCTAssertEqual(InputRemappingRuleMatcher.scrollRule(for: .up, flags: [.maskCommand], in: [rule])?.id, rule.id)
        XCTAssertNil(InputRemappingRuleMatcher.scrollRule(for: .down, flags: [.maskCommand], in: [rule]))
        XCTAssertNil(InputRemappingRuleMatcher.scrollRule(for: .up, flags: [], in: [rule]))
    }

    @MainActor
    func testTrackpadGestureClaimExecutesOnlyItsMappedAction() throws {
        let tap = InputRemappingTapSpy()
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: InputRemappingMemoryStorage()),
            tap: tap,
            accessibilityTrusted: { true },
            inputMonitoringStatus: { .granted }
        )
        plugin.store.addRule()
        var rule = try XCTUnwrap(plugin.store.rules.first)
        rule.replaceTrigger(.trackpadGesture(.threeFingerTap))
        rule.action = .mouseBack
        rule.isInputConfigured = true
        rule.isOutputConfigured = true
        rule.isEnabled = true
        plugin.store.replace(rule)

        XCTAssertEqual(plugin.claimedTrackpadGestures, [.threeFingerTap])
        plugin.setOwnedTrackpadGestures([.threeFingerTap])
        plugin.receiveTrackpadGesture(.threeFingerTap, deviceID: 1)
        XCTAssertEqual(tap.executedActions, [.mouseBack])

        plugin.setOwnedTrackpadGestures([])
        plugin.receiveTrackpadGesture(.threeFingerTap, deviceID: 1)
        XCTAssertEqual(tap.executedActions, [.mouseBack])
        XCTAssertEqual(plugin.store.rules.count, 1)
    }

    func testFailedOrInapplicableDownAndUnpairedUpFailOpen() {
        let rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        var processor = InputRemappingEventProcessor()

        XCTAssertFalse(processor.shouldConsume(
            phase: .down,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in false }
        ))
        XCTAssertFalse(processor.shouldConsume(
            phase: .up,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in true }
        ))
        XCTAssertFalse(processor.shouldConsume(
            phase: .down,
            buttonNumber: 5,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in XCTFail("An inapplicable rule must not execute"); return true }
        ))
    }

    func testEventsMarkedByInputRemappingAlwaysPassThrough() {
        let rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        var processor = InputRemappingEventProcessor()

        XCTAssertFalse(processor.shouldConsume(
            phase: .down,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: true,
            rules: [rule],
            execute: { _ in XCTFail("Marked event must not execute"); return true }
        ))
    }

    @MainActor
    func testStorePersistsAndReloadsRules() throws {
        let storage = InputRemappingMemoryStorage()
        let firstStore = InputRemappingStore(storage: storage)
        firstStore.addRule()
        let savedRule = try XCTUnwrap(firstStore.rules.first)
        var editedRule = savedRule
        editedRule.buttonNumber = 7
        editedRule.action = .volumeUp
        firstStore.replace(editedRule)

        let secondStore = InputRemappingStore(storage: storage)

        XCTAssertEqual(secondStore.rules, [editedRule])
    }

    @MainActor
    func testEmergencyStopDisablesOnlyUnsafeTriggers() throws {
        let storage = InputRemappingMemoryStorage()
        let unsafeRule = InputRemappingRule(
            isEnabled: true,
            trigger: .mouseButton(number: 0, modifiers: [], interaction: .click),
            action: .mouseBack,
            isUnsafeTriggerConfirmed: true
        )
        let safeRule = InputRemappingRule(buttonNumber: 4, action: .mouseForward)
        storage.set(try JSONEncoder().encode([unsafeRule, safeRule]), forKey: "input-remapping.rules.v1")
        let store = InputRemappingStore(storage: storage)
        store.disableUnsafeTriggers()

        XCTAssertFalse(store.rules[0].isEnabled)
        XCTAssertFalse(store.rules[0].isUnsafeTriggerConfirmed)
        XCTAssertTrue(store.rules[1].isEnabled)
    }

    @MainActor
    func testRulesStartOnlyWithBothPermissionsAndEveryDeactivationStopsTap() throws {
        let storage = InputRemappingMemoryStorage()
        let store = InputRemappingStore(storage: storage)
        store.addRule()
        var rule = try XCTUnwrap(store.rules.first)
        rule.buttonNumber = 3
        rule.isInputConfigured = true
        rule.isOutputConfigured = true
        rule.isEnabled = true
        store.replace(rule)
        let tap = InputRemappingTapSpy()
        let permissionState = InputRemappingPermissionState()
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: storage),
            tap: tap,
            accessibilityTrusted: { true },
            inputMonitoringStatus: { permissionState.inputMonitoringStatus }
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "input-remapping"))
        XCTAssertEqual(tap.startCallCount, 0)
        XCTAssertGreaterThan(tap.stopCallCount, 0)

        permissionState.inputMonitoringStatus = .granted
        plugin.refresh()
        XCTAssertEqual(tap.startCallCount, 1)

        plugin.deactivate(reason: .updating)
        XCTAssertGreaterThanOrEqual(tap.stopCallCount, 2)
    }

    @MainActor
    func testInputCaptureStartFailurePublishesRuleLocalErrorAndRetryClearsIt() {
        let tap = InputRemappingTapSpy()
        tap.startResult = false
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { $0() }
        )
        let ruleID = UUID()
        var failureCalled = false

        XCTAssertFalse(coordinator.start(ruleID: ruleID, onCapture: { _ in }, onFailure: { failureCalled = true }))
        XCTAssertTrue(failureCalled)
        XCTAssertEqual(
            coordinator.recordingError,
            InputRemappingRecordingError(
                ruleID: ruleID,
                target: .input,
                failure: .eventTapUnavailable
            )
        )
        XCTAssertNil(coordinator.preparingRuleID)
        XCTAssertNil(coordinator.recordingRuleID)

        coordinator.cancel()
        XCTAssertNil(coordinator.recordingError)
    }

}
