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
        return startResult
    }

    func beginShortcutCapture(_ handler: @escaping @Sendable (ShortcutBinding) -> Void) -> Bool {
        shortcutCaptureHandler = handler
        return startResult
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

private final class InputRemappingCaptureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [InputRemappingCapturedInput] = []

    func append(_ value: InputRemappingCapturedInput) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [InputRemappingCapturedInput] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
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

    @MainActor
    func testPrimaryPanelTitleNamesSupportedInputSources() {
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: InputRemappingMemoryStorage()),
            tap: InputRemappingTapSpy(),
            accessibilityTrusted: { true },
            inputMonitoringStatus: { .granted }
        )

        XCTAssertTrue(plugin.metadata.title.contains(":"))
        XCTAssertEqual(plugin.metadata.title.filter { $0 == "," }.count, 2)
        XCTAssertFalse(plugin.metadata.title.contains("⌨️"))
        XCTAssertEqual(plugin.metadata.defaultDescription, "Map inputs to actions")
        XCTAssertEqual(plugin.metadata.iconName, "arrow.left.arrow.right")
    }

    func testShortcutActionKindStaysSelectedAfterRecording() {
        let recorded = InputRemappingRule.Action.shortcut(ShortcutBinding(keyCode: 21, modifiers: [.command, .shift]))

        XCTAssertEqual(recorded.kind, .shortcut)
        XCTAssertEqual(recorded.replacingKind(.shortcut), recorded)
    }

    func testSingleKeyActionKindStaysSelectedAndPersistsRightCommand() throws {
        let recorded = InputRemappingRule.Action.keyTap(
            KeyboardKeyTap(keyCode: UInt16(kVK_RightCommand))
        )

        XCTAssertEqual(recorded.kind, .keyTap)
        XCTAssertEqual(recorded.replacingKind(.keyTap), recorded)

        let rule = InputRemappingRule(action: recorded)
        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(InputRemappingRule.self, from: data), rule)
    }

    func testOutputRecordingCancelRestoresConfiguredSingleKey() {
        let original = InputRemappingRule(
            isEnabled: true,
            action: .keyTap(KeyboardKeyTap(keyCode: UInt16(kVK_RightCommand)))
        )
        let snapshot = InputRemappingOutputRecordingSnapshot(rule: original)
        var draft = original
        draft.action = .keyTap(nil)
        draft.outputConfigurationState = .recordingKeyTap
        draft.isEnabled = false

        snapshot.restore(&draft)

        XCTAssertEqual(draft.action, original.action)
        XCTAssertEqual(draft.outputConfigurationState, .configured)
        XCTAssertTrue(draft.isEnabled)
    }

    func testOutputRecordingCancelRestoresActionBeforeTemporaryShortcutSelection() {
        let original = InputRemappingRule(
            isEnabled: true,
            action: .mouseForward
        )
        let snapshot = InputRemappingOutputRecordingSnapshot(rule: original)
        var draft = original
        draft.action = .shortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]))
        draft.outputConfigurationState = .recordingShortcut
        draft.isEnabled = false

        snapshot.restore(&draft)

        XCTAssertEqual(draft.action, .mouseForward)
        XCTAssertEqual(draft.outputConfigurationState, .configured)
        XCTAssertTrue(draft.isEnabled)
    }

    func testIncompleteSingleKeyReloadsAsUnsetInsteadOfA() throws {
        var rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        rule.action = .keyTap(nil)
        rule.outputConfigurationState = .recordingKeyTap
        rule.isEnabled = false

        let decoded = try JSONDecoder().decode(
            InputRemappingRule.self,
            from: JSONEncoder().encode(rule)
        )

        XCTAssertEqual(decoded.action, .keyTap(nil))
        XCTAssertEqual(decoded.outputConfigurationState, .needsSelection)
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertNotEqual(KeyboardKeyTapFormatter.displayString(for: nil), "A")
    }

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

    func testRuleNormalizesButtonNumberUsingSharedPolicy() {
        XCTAssertEqual(
            InputRemappingRule(buttonNumber: -1).buttonNumber,
            InputRemappingRulePolicy.minimumButtonNumber
        )
        XCTAssertEqual(
            InputRemappingRule(buttonNumber: 100).buttonNumber,
            InputRemappingRulePolicy.maximumButtonNumber
        )
    }

    func testNewDraftRequiresRecordedInputAndOutput() {
        let draft = InputRemappingRule.newDraft()

        XCTAssertFalse(draft.isEnabled)
        XCTAssertFalse(draft.isInputConfigured)
        XCTAssertFalse(draft.isOutputConfigured)
        XCTAssertEqual(draft.outputConfigurationState, .needsSelection)
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

    func testLegacyRuleDecodingTreatsBothSidesAsConfigured() throws {
        let rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        payload.removeValue(forKey: "isInputConfigured")
        payload.removeValue(forKey: "outputConfigurationState")

        let decoded = try JSONDecoder().decode(InputRemappingRule.self, from: JSONSerialization.data(withJSONObject: payload))

        XCTAssertTrue(decoded.isInputConfigured)
        XCTAssertTrue(decoded.isOutputConfigured)
    }

    func testConfirmedUnmodifiedKeyboardRuleStaysEnabledAfterReload() throws {
        let rule = InputRemappingRule(
            isEnabled: true,
            trigger: .keyboard(keyCode: 12, modifiers: []),
            action: .mouseBack,
            isUnsafeTriggerConfirmed: true
        )

        let decoded = try JSONDecoder().decode(
            InputRemappingRule.self,
            from: JSONEncoder().encode(rule)
        )

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertTrue(decoded.isUnsafeTriggerConfirmed)
    }

    func testLegacyKeyboardConfirmationMigratesToUnsafeTriggerConfirmation() throws {
        let rule = InputRemappingRule(
            isEnabled: true,
            trigger: .keyboard(keyCode: 12, modifiers: []),
            action: .mouseBack,
            isUnsafeTriggerConfirmed: true
        )
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        payload["isUnmodifiedKeyboardConfirmed"] = payload.removeValue(forKey: "isUnsafeTriggerConfirmed")

        let decoded = try JSONDecoder().decode(
            InputRemappingRule.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertTrue(decoded.isUnsafeTriggerConfirmed)
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

    func testDoubleClickRequiresTheSameModifiersAcrossBothClicks() {
        let rule = InputRemappingRule(
            trigger: .mouseButton(number: 4, modifiers: [.command], interaction: .doubleClick),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskAlternate], isMarkedSynthetic: false, rules: [rule], timestamp: 1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [.maskAlternate], isMarkedSynthetic: false, rules: [rule], timestamp: 1.01, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1.1, execute: { _ in executions += 1; return true }))

        XCTAssertEqual(executions, 0)
    }

    func testDoubleClickRequiresModifiersAcrossEachCompleteClick() {
        let rule = InputRemappingRule(
            trigger: .mouseButton(number: 4, modifiers: [.command], interaction: .doubleClick),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.01, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1.1, execute: { _ in executions += 1; return true }))

        XCTAssertEqual(executions, 0)
    }

    func testDoubleClickValidatesTheSecondMouseUpBeforeExecuting() {
        let rule = InputRemappingRule(
            trigger: .mouseButton(number: 4, modifiers: [.command], interaction: .doubleClick),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1.01, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 1.1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.11, execute: { _ in executions += 1; return true }))

        XCTAssertEqual(executions, 0)
    }

    func testLongPressRequiresTheSameModifiersFromDownThroughUp() {
        let rule = InputRemappingRule(
            trigger: .mouseButton(number: 4, modifiers: [.command], interaction: .longPress),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [.maskAlternate], isMarkedSynthetic: false, rules: [rule], timestamp: 1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [.maskCommand], isMarkedSynthetic: false, rules: [rule], timestamp: 2, execute: { _ in executions += 1; return true }))

        XCTAssertEqual(executions, 0)
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

    func testInputCaptureConsumesHeldKeyRepeatsAndMatchingKeyUp() {
        let tap = InputRemappingEventTap(captureStartResult: true)
        let captured = InputRemappingCaptureRecorder()
        XCTAssertTrue(tap.beginInputCapture { captured.append($0) })
        defer { tap.stop() }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 21, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 21, keyDown: false)!

        XCTAssertNil(tap.handle(type: .keyDown, event: down))
        XCTAssertTrue(tap.isCaptureSequenceActive)
        XCTAssertNil(tap.handle(type: .keyDown, event: down))
        XCTAssertNil(tap.handle(type: .keyUp, event: up))
        XCTAssertFalse(tap.isCaptureSequenceActive)
        XCTAssertEqual(captured.snapshot, [.keyboard(keyCode: 21, modifiers: [])])
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

    func testInputCaptureConsumesScrollUntilItBecomesQuiet() {
        let tap = InputRemappingEventTap(captureStartResult: true)
        let captured = InputRemappingCaptureRecorder()
        XCTAssertTrue(tap.beginInputCapture { captured.append($0) })
        defer { tap.stop() }
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        scroll.timestamp = 1_000_000_000
        let momentum = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        momentum.timestamp = 1_100_000_000

        XCTAssertNil(tap.handle(type: .scrollWheel, event: scroll))
        XCTAssertNil(tap.handle(type: .scrollWheel, event: momentum))
        XCTAssertTrue(tap.isCaptureSequenceActive)
        XCTAssertEqual(captured.snapshot, [.scroll(direction: .up, modifiers: [])])
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

    func testDisabledOrIncompleteTrackpadRuleDoesNotClaimOwnership() {
        var rule = InputRemappingRule.newDraft()
        rule.replaceTrigger(.trackpadGesture(.threeFingerTap))
        rule.isInputConfigured = true

        XCTAssertNil(rule.claimedTrackpadGesture)

        rule.isOutputConfigured = true
        rule.isEnabled = true

        XCTAssertEqual(rule.claimedTrackpadGesture, .threeFingerTap)
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

    func testSyntheticEventMarkerIsRecognizedBeforeCapture() {
        for marker in [
            MacToolsSyntheticInputEvent.marker,
            MacToolsSyntheticInputEvent.legacyTrackpadGesturesMarker,
            MacToolsSyntheticInputEvent.supersededSharedMarker,
        ] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 21, keyDown: true)!
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            XCTAssertTrue(InputRemappingEventTap.isMarkedSynthetic(event))
        }
    }

    func testSystemDefinedMediaEventEncodesDownAndUpStateOnce() {
        let keyType: Int32 = 16

        XCTAssertEqual(
            InputRemappingSystemDefinedEvent.data1(
                keyType: keyType,
                state: InputRemappingSystemDefinedEvent.keyDownState
            ),
            Int((keyType << 16) | 0xA00)
        )
        XCTAssertEqual(
            InputRemappingSystemDefinedEvent.data1(
                keyType: keyType,
                state: InputRemappingSystemDefinedEvent.keyUpState
            ),
            Int((keyType << 16) | 0xB00)
        )
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
    func testStoreNormalizesCopiedAndPersistedButtonNumbers() throws {
        let storage = InputRemappingMemoryStorage()
        let store = InputRemappingStore(storage: storage)
        store.addRule()
        var copiedRule = try XCTUnwrap(store.rules.first)
        copiedRule.buttonNumber = 99
        store.replace(copiedRule)
        XCTAssertEqual(store.rules.first?.buttonNumber, InputRemappingRulePolicy.maximumButtonNumber)

        let data = try XCTUnwrap(storage.data(forKey: "input-remapping.rules.v1"))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var trigger = try XCTUnwrap(payload[0]["trigger"] as? [String: Any])
        trigger["number"] = -1
        payload[0]["trigger"] = trigger
        storage.set(try JSONSerialization.data(withJSONObject: payload), forKey: "input-remapping.rules.v1")

        let reloadedStore = InputRemappingStore(storage: storage)
        XCTAssertEqual(
            reloadedStore.rules.first?.buttonNumber,
            InputRemappingRulePolicy.minimumButtonNumber
        )
    }

    @MainActor
    func testPermissionStatesReflectProvidersAndActionsAreReal() {
        let tap = InputRemappingTapSpy()
        var requestedAccessibility = false
        var openedURL: URL?
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(
                pluginID: "input-remapping",
                storage: InputRemappingMemoryStorage()
            ),
            tap: tap,
            accessibilityTrusted: { requestedAccessibility },
            requestAccessibilityTrust: { prompt in
                requestedAccessibility = prompt
                return requestedAccessibility
            },
            inputMonitoringStatus: { .denied },
            openURL: { openedURL = $0 }
        )

        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
        XCTAssertFalse(plugin.permissionState(for: "input-monitoring").isGranted)
        XCTAssertFalse(plugin.permissionState(for: "unknown").isGranted)

        plugin.handlePermissionAction(id: "accessibility")
        XCTAssertTrue(plugin.permissionState(for: "accessibility").isGranted)

        plugin.handlePermissionAction(id: "input-monitoring")
        XCTAssertTrue(openedURL?.absoluteString.contains("Privacy_ListenEvent") == true)
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
    func testAppReactivationResamplesPermissionsAndDeactivationRemovesObserver() async throws {
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
        let notificationCenter = NotificationCenter()
        let permissionState = InputRemappingPermissionState()
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: storage),
            tap: tap,
            accessibilityTrusted: { permissionState.accessibilityGranted },
            inputMonitoringStatus: { permissionState.inputMonitoringStatus },
            notificationCenter: notificationCenter
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "input-remapping"))
        XCTAssertEqual(tap.startCallCount, 0)

        permissionState.accessibilityGranted = true
        permissionState.inputMonitoringStatus = .granted
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(tap.startCallCount, 1)

        permissionState.accessibilityGranted = false
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertGreaterThan(tap.stopCallCount, 0)

        plugin.deactivate(reason: .disabled)
        let startCountAfterDeactivation = tap.startCallCount
        permissionState.accessibilityGranted = true
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(tap.startCallCount, startCountAfterDeactivation)
    }

    @MainActor
    func testSettingsPageUsesValidWorkspaceContract() throws {
        let tap = InputRemappingTapSpy()
        let buttonCapture = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { $0() }
        )
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(
                pluginID: "input-remapping",
                storage: InputRemappingMemoryStorage()
            ),
            tap: tap,
            buttonCapture: buttonCapture,
            accessibilityTrusted: { false },
            inputMonitoringStatus: { .denied }
        )
        let page = try XCTUnwrap(plugin.settingsPage)

        XCTAssertEqual(page.body.layout, .workspace)
        guard case let .workspace(workspace) = page.body else {
            return XCTFail("Expected workspace settings")
        }
        XCTAssertEqual(workspace.scrolling, .host)
        XCTAssertNoThrow(try PluginSettingsValidator.validate(page))
        XCTAssertNotNil(page.visibilityHandler)

        XCTAssertTrue(buttonCapture.start(ruleID: UUID()) { _ in })
        XCTAssertNotNil(buttonCapture.recordingRuleID)
        page.visibilityHandler?(false)
        XCTAssertNil(buttonCapture.recordingRuleID)
        XCTAssertEqual(tap.cancelCaptureCallCount, 1)
    }

    @MainActor
    func testTrackpadOnlyRuleDoesNotStartGlobalEventTap() throws {
        let storage = InputRemappingMemoryStorage()
        let store = InputRemappingStore(storage: storage)
        store.addRule()
        var rule = try XCTUnwrap(store.rules.first)
        rule.replaceTrigger(.trackpadGesture(.threeFingerTap))
        rule.isInputConfigured = true
        rule.isOutputConfigured = true
        rule.isEnabled = true
        store.replace(rule)
        let tap = InputRemappingTapSpy()
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: storage),
            tap: tap,
            accessibilityTrusted: { true },
            inputMonitoringStatus: { .denied }
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "input-remapping"))

        XCTAssertEqual(tap.startCallCount, 0)
    }

    @MainActor
    func testButtonCaptureRecordsAnEligibleButtonAndCanBeCancelled() async {
        let tap = InputRemappingTapSpy()
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { $0() }
        )
        var capturedInput: InputRemappingCapturedInput?

        XCTAssertTrue(coordinator.start(ruleID: UUID()) {
            capturedInput = $0
        })
        tap.capture(.mouseButton(number: 4, modifiers: []))
        await Task.yield()

        XCTAssertEqual(capturedInput, .mouseButton(number: 4, modifiers: []))
        XCTAssertNil(coordinator.recordingRuleID)

        XCTAssertTrue(coordinator.start(ruleID: UUID()) { _ in })
        coordinator.cancel()
        XCTAssertNil(coordinator.recordingRuleID)
        XCTAssertEqual(tap.cancelCaptureCallCount, 1)
    }

    @MainActor
    func testShortcutCaptureRecordsAKeyboardBinding() async {
        let tap = InputRemappingTapSpy()
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { $0() }
        )
        var captured: ShortcutBinding?

        XCTAssertTrue(coordinator.startShortcut(ruleID: UUID()) { captured = $0 })
        tap.capture(shortcut: ShortcutBinding(keyCode: 12, modifiers: [.command]))
        await Task.yield()

        XCTAssertEqual(captured, ShortcutBinding(keyCode: 12, modifiers: [.command]))
        XCTAssertNil(coordinator.recordingShortcutRuleID)
    }

    @MainActor
    func testInputCaptureIgnoresTheClickThatOpenedRecording() async throws {
        let tap = InputRemappingTapSpy()
        var pendingArming: (@MainActor () -> Void)?
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { pendingArming = $0 }
        )
        var captured: InputRemappingCapturedInput?

        XCTAssertTrue(coordinator.start(ruleID: UUID()) { captured = $0 })
        XCTAssertNotNil(coordinator.preparingRuleID)
        XCTAssertEqual(tap.startCallCount, 1)
        tap.capture(.mouseButton(number: 0, modifiers: []))
        await Task.yield()
        XCTAssertNil(captured)

        let arm = try XCTUnwrap(pendingArming)
        arm()
        tap.capture(.mouseButton(number: 4, modifiers: []))
        await Task.yield()
        XCTAssertEqual(captured, .mouseButton(number: 4, modifiers: []))
    }

    @MainActor
    func testEmergencyStopCancelsAPreparingRecorder() {
        let tap = InputRemappingTapSpy()
        var pendingArming: (@MainActor () -> Void)?
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { pendingArming = $0 }
        )

        XCTAssertTrue(coordinator.start(ruleID: UUID()) { _ in })
        XCTAssertNotNil(coordinator.preparingRuleID)

        coordinator.cancelFromEmergencyStop()
        XCTAssertNil(coordinator.preparingRuleID)

        pendingArming?()
        XCTAssertNil(coordinator.recordingRuleID)
    }

    @MainActor
    func testEmergencyStopHandlerResetsThePluginRecorderState() async {
        let tap = InputRemappingTapSpy()
        var pendingArming: (@MainActor () -> Void)?
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { pendingArming = $0 }
        )
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(
                pluginID: "input-remapping",
                storage: InputRemappingMemoryStorage()
            ),
            tap: tap,
            buttonCapture: coordinator
        )

        XCTAssertTrue(coordinator.start(ruleID: UUID()) { _ in })
        XCTAssertNotNil(coordinator.preparingRuleID)

        tap.emergencyStopHandler?()
        await Task.yield()

        XCTAssertNil(coordinator.preparingRuleID)
        pendingArming?()
        XCTAssertNil(coordinator.recordingRuleID)
        plugin.deactivate(reason: .disabled)
    }
}
