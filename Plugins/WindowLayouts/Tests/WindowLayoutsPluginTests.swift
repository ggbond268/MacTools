import Carbon
import XCTest
import MacToolsPluginKit
@testable import WindowLayoutsPlugin

@MainActor
final class WindowLayoutsPluginTests: XCTestCase {
    func testPermissionMembershipTracksCustomCommandsAndRejectsUnknownProviders() throws {
        let plugin = makePlugin()
        plugin.performActionShortcutReplacementTransaction = { _, _, commit in commit() }
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first {
            $0.key.actionID.hasPrefix("custom.")
        })
        let id = try XCTUnwrap(UUID(uuidString: String(definition.key.actionID.dropFirst("custom.".count))))

        XCTAssertEqual(plugin.permissionRequirementIDs(for: definition.key), ["accessibility"])
        XCTAssertTrue(plugin.permissionRequirementIDs(for: .init(providerID: "another-plugin",
            actionID: definition.key.actionID)).isEmpty)
        XCTAssertTrue(plugin.permissionRequirementIDs(for: .init(providerID: plugin.metadata.id,
            actionID: "unknown-action")).isEmpty)
        XCTAssertTrue(plugin.deleteCustomCommand(id))
        XCTAssertTrue(plugin.permissionRequirementIDs(for: definition.key).isEmpty)
        XCTAssertFalse(plugin.actionShortcutSettingsConfiguration.actionIDs.contains(definition.key.actionID))
    }

    func testAvailabilityChecksPermissionWithoutResolvingEveryWindow() throws {
        let executor = MockWindowLayoutExecutor()
        executor.validationError = .noFocusedWindow
        let denied = makePlugin(executor: executor, accessibilityTrusted: { false })
        let deniedReference = try XCTUnwrap(denied.actionCatalogEntries.first?.reference)

        XCTAssertFalse(denied.actionAvailability(for: deniedReference).isAvailable)

        let permitted = makePlugin(executor: executor)
        let permittedReference = try XCTUnwrap(permitted.actionCatalogEntries.first?.reference)
        let availability = permitted.actionAvailability(for: permittedReference)
        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(executor.validationCallCount, 0)
    }

    func testShortcutPresetAssistantRequiresPreviewAndExplicitApply() throws {
        let plugin = makePlugin()
        var managedActionIDs: Set<String> = []
        var bindingsByActionID: [String: ShortcutBinding] = [:]
        var currentBindings: [String: ShortcutBinding] = [:]
        plugin.previewActionShortcutPreset = { actionIDs, proposedBindings in
            PluginActionShortcutPresetPreview(items: actionIDs.sorted().map { actionID in
                PluginActionShortcutPresetPreviewItem(
                    actionID: actionID,
                    currentBinding: currentBindings[actionID],
                    proposedBinding: proposedBindings[actionID]
                )
            })
        }
        plugin.applyActionShortcutPreset = { actionIDs, bindings in
            managedActionIDs = actionIDs
            bindingsByActionID = bindings
            currentBindings = bindings
            return nil
        }

        let controlOptionPreview = try XCTUnwrap(
            plugin.shortcutPresetPreview(for: .controlOption)
        )

        XCTAssertTrue(controlOptionPreview.hasChanges)
        XCTAssertTrue(managedActionIDs.isEmpty)
        XCTAssertTrue(bindingsByActionID.isEmpty)

        guard case let .form(sections) = try XCTUnwrap(plugin.settingsPage).body,
              let presetSection = sections.first(where: { $0.id == "shortcut-presets" }),
              case .custom = presetSection.content
        else {
            return XCTFail("Expected the shortcut preset assistant section")
        }

        XCTAssertNil(plugin.applyShortcutPreset(.controlOption))

        XCTAssertEqual(managedActionIDs.count, 8)
        XCTAssertEqual(bindingsByActionID.count, 6)
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.leftHalf.rawValue]?.modifiers,
            [.control, .option]
        )
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.leftHalf.rawValue]?.keyCode,
            UInt16(kVK_LeftArrow)
        )
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.rightHalf.rawValue]?.keyCode,
            UInt16(kVK_RightArrow)
        )
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.topHalf.rawValue]?.keyCode,
            UInt16(kVK_UpArrow)
        )
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.bottomHalf.rawValue]?.keyCode,
            UInt16(kVK_DownArrow)
        )

        let optionCommandPreview = try XCTUnwrap(
            plugin.shortcutPresetPreview(for: .optionCommand)
        )

        XCTAssertTrue(optionCommandPreview.hasChanges)
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.leftHalf.rawValue]?.modifiers,
            [.control, .option]
        )

        XCTAssertNil(plugin.applyShortcutPreset(.optionCommand))

        XCTAssertEqual(managedActionIDs.count, 8)
        XCTAssertEqual(bindingsByActionID.count, 6)
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.leftHalf.rawValue],
            ShortcutBinding(
                keyCode: UInt16(kVK_LeftArrow),
                modifiers: [.option, .command]
            )
        )
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.maximize.rawValue],
            ShortcutBinding(
                keyCode: UInt16(kVK_ANSI_F),
                modifiers: [.option, .command]
            )
        )

        var customizedBindings = plugin.shortcutPresetBindings(for: .optionCommand)
        customizedBindings[WindowLayoutOperation.center.rawValue] = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_M),
            modifiers: [.option, .command]
        )
        let customizedPreview = try XCTUnwrap(
            plugin.shortcutPresetPreview(bindingsByActionID: customizedBindings)
        )
        XCTAssertTrue(customizedPreview.hasChanges)

        XCTAssertNil(plugin.applyShortcutPreset(
            .optionCommand,
            bindingsByActionID: customizedBindings
        ))
        XCTAssertEqual(
            bindingsByActionID[WindowLayoutOperation.center.rawValue],
            ShortcutBinding(
                keyCode: UInt16(kVK_ANSI_M),
                modifiers: [.option, .command]
            )
        )

        currentBindings[WindowLayoutOperation.leftHalf.rawValue] = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_A),
            modifiers: [.control, .shift]
        )
        XCTAssertNil(plugin.currentShortcutPreset)
        XCTAssertEqual(plugin.initialShortcutPreset, .optionCommand)
    }

    func testModifierDragIsOptInPublishesExactClaimAndPausesForConflict() {
        let session = MockWindowModifierDragSession()
        let plugin = makePlugin(modifierDragSession: session)

        plugin.activate(context: PluginRuntimeContext(pluginID: "window-layouts"))
        XCTAssertTrue(plugin.activeInputGestureClaims.isEmpty)
        XCTAssertEqual(session.startCount, 0)

        plugin.setModifierDragEnabled(true)

        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(session.configuredModifiers, [.control, .option])
        XCTAssertEqual(session.configuredShowsIndicator, true)
        XCTAssertEqual(
            plugin.activeInputGestureClaims.map(\.id),
            ["pointer.move.modifiers.6"]
        )

        plugin.setShowsModifierDragIndicator(false)
        XCTAssertEqual(session.configuredShowsIndicator, false)

        plugin.setModifierDragModifiers([.shift, .command])
        XCTAssertEqual(session.configuredModifiers, [.shift, .command])
        XCTAssertEqual(session.configuredShowsIndicator, false)
        XCTAssertEqual(
            plugin.activeInputGestureClaims.map(\.id),
            ["pointer.move.modifiers.9"]
        )

        let conflict = PluginInputGestureConflict(
            claim: PluginInputGestureClaim(
                id: "pointer.move.modifiers.9",
                title: "Modifier Drag"
            ),
            ownerPluginID: "other-plugin",
            ownerPluginTitle: "Other Plugin"
        )
        var stateChangeCount = 0
        plugin.onStateChange = { stateChangeCount += 1 }
        plugin.inputGestureConflictsDidChange([conflict])

        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(
            plugin.activeInputGestureClaims.map(\.id),
            ["pointer.move.modifiers.9"],
            "A paused owner must retain its claim so conflict resolution stays stable"
        )
        XCTAssertEqual(stateChangeCount, 0)

        let configureCountAfterConflict = session.configureCount
        plugin.inputGestureConflictsDidChange([conflict])
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(session.configureCount, configureCountAfterConflict)
        XCTAssertEqual(stateChangeCount, 0)

        let startCountBeforeResume = session.startCount
        plugin.inputGestureConflictsDidChange([])
        XCTAssertEqual(session.startCount, startCountBeforeResume + 1)
        XCTAssertEqual(stateChangeCount, 0)
    }

    func testDeletingCustomCommandClearsItsShortcutBeforeRemovingAction() throws {
        let plugin = makePlugin()
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))
        let id = try XCTUnwrap(UUID(uuidString: String(
            definition.key.actionID.dropFirst("custom.".count)
        )))
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_L),
            modifiers: [.control, .option]
        )
        let shortcutState = WindowLayoutsShortcutState(
            bindings: [definition.key.actionID: binding]
        )
        configureShortcutHost(plugin, state: shortcutState)

        XCTAssertTrue(plugin.deleteCustomCommand(id))

        XCTAssertNil(shortcutState.bindings[definition.key.actionID])
        XCTAssertFalse(plugin.actionDefinitions.contains(where: {
            $0.key.actionID == definition.key.actionID
        }))
        XCTAssertNil(plugin.customCommandDeletionError)
    }

    func testShortcutClearFailureKeepsCustomCommand() throws {
        let plugin = makePlugin()
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))
        let id = try XCTUnwrap(UUID(uuidString: String(
            definition.key.actionID.dropFirst("custom.".count)
        )))
        plugin.performActionShortcutReplacementTransaction = { _, _, _ in
            "Shortcut storage failed"
        }

        XCTAssertFalse(plugin.deleteCustomCommand(id))

        XCTAssertTrue(plugin.actionDefinitions.contains(where: {
            $0.key.actionID == definition.key.actionID
        }))
        XCTAssertEqual(plugin.customCommandDeletionError, "Shortcut storage failed")
    }

    func testUpdatingCustomCommandNormalizesBlankNameAndPersistsOtherEdits() throws {
        let plugin = makePlugin()
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))
        let id = try XCTUnwrap(UUID(uuidString: String(
            definition.key.actionID.dropFirst("custom.".count)
        )))
        var command = try XCTUnwrap(plugin.customCommand(id: id))
        command.name = "  \n "
        command.width = .fraction(0.35)
        command.anchor = .bottomRight

        XCTAssertTrue(plugin.updateCustomCommand(command))

        let stored = try XCTUnwrap(plugin.customCommand(id: command.id))
        XCTAssertEqual(
            stored.name,
            plugin.localizedKey("settings.custom.defaultName", "自定义布局")
        )
        XCTAssertEqual(stored.width, .fraction(0.35))
        XCTAssertEqual(stored.anchor, .bottomRight)
    }

    func testActionExecutionUsesCommittedGapAndReset() async throws {
        let executor = MockWindowLayoutExecutor()
        let plugin = makePlugin(executor: executor)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first(where: {
            $0.reference.key.actionID == WindowLayoutOperation.leftHalf.rawValue
        })?.reference)

        plugin.handleSettingsAction(.setNumber(
            controlID: "gap",
            value: 17,
            phase: .committed
        ))
        let firstResult = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(firstResult, .succeeded())
        XCTAssertEqual(executor.executions.last?.operation, .leftHalf)
        XCTAssertEqual(executor.executions.last?.gap, 17)

        plugin.handleSettingsAction(.invoke(controlID: "reset"))
        _ = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()
        XCTAssertEqual(executor.executions.last?.gap, 0)
    }

    func testExecutionRechecksPermissionAfterAvailability() async throws {
        let executor = MockWindowLayoutExecutor()
        let trustState = WindowLayoutsTrustState(isTrusted: true)
        let plugin = makePlugin(
            executor: executor,
            accessibilityTrusted: { trustState.isTrusted }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)

        trustState.isTrusted = false
        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected permission failure")
        }
        XCTAssertTrue(executor.executions.isEmpty)
    }

    func testCancelledServiceExecutionPropagatesAsCancelledActionResult() async throws {
        let executor = MockWindowLayoutExecutor()
        executor.executionError = .executionCancelled
        let plugin = makePlugin(executor: executor)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))
        let result = await handle.result()

        XCTAssertEqual(result, .cancelled)
    }

    func testBeginActionSnapshotsCustomCommandBeforeDeletion() async throws {
        let executor = MockWindowLayoutExecutor()
        let plugin = makePlugin(executor: executor)
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))
        let handle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .test,
            mode: .background
        ))

        plugin.handleSettingsAction(.invoke(controlID: "\(definition.key.actionID).delete"))
        let result = await handle.result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(executor.customExecutions.map(\.name), [definition.title])
    }

    func testIncrementalResizeActionDefinitionsAndExecution() async throws {
        let executor = MockWindowLayoutExecutor()
        let plugin = makePlugin(executor: executor)

        let incrementalOps: [WindowLayoutOperation] = [
            .increaseWidth,
            .decreaseWidth,
            .increaseHeight,
            .decreaseHeight,
        ]

        for op in incrementalOps {
            let definition = try XCTUnwrap(
                plugin.actionDefinitions.first(where: { $0.key.actionID == op.rawValue })
            )
            XCTAssertFalse(definition.title.isEmpty)
            XCTAssertFalse(definition.description.isEmpty)
            XCTAssertFalse(definition.systemImage.isEmpty)
            XCTAssertEqual(definition.risk, .safe)
            XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
            XCTAssertEqual(
                plugin.permissionRequirementIDs(for: definition.key),
                ["accessibility"]
            )

            let handle = try plugin.beginAction(ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .unifiedSearch,
                mode: .foreground
            ))
            let result = await handle.result()
            XCTAssertEqual(result, .succeeded())
        }
        XCTAssertEqual(executor.executions.map(\.operation), incrementalOps)

        executor.executionError = .windowCannotResizeFurther
        let failureHandle = try plugin.beginAction(ActionInvocation(
            reference: ActionReference(key: ActionKey(providerID: "window-layouts", actionID: "increase-width")),
            source: .unifiedSearch,
            mode: .foreground
        ))
        let failureResult = await failureHandle.result()
        XCTAssertEqual(failureResult, .failed(message: "窗口无法进一步调整大小。"))
    }

    private func makePlugin(
        executor: MockWindowLayoutExecutor? = nil,
        storage: PluginStorage? = nil,
        modifierDragSession: (any WindowModifierDragSessionManaging)? = nil,
        accessibilityTrusted: @escaping @MainActor @Sendable () -> Bool = { true }
    ) -> WindowLayoutsPlugin {
        WindowLayoutsPlugin(
            context: PluginRuntimeContext(
                pluginID: "window-layouts",
                storage: storage ?? WindowLayoutsMemoryStorage()
            ),
            executor: executor ?? MockWindowLayoutExecutor(),
            makeModifierDragSession: {
                modifierDragSession ?? MockWindowModifierDragSession()
            },
            accessibilityTrusted: accessibilityTrusted,
            requestAccessibilityTrust: { _ in accessibilityTrusted() }
        )
    }

    private func configureShortcutHost(
        _ plugin: WindowLayoutsPlugin,
        state: WindowLayoutsShortcutState
    ) {
        plugin.previewActionShortcutPreset = { actionIDs, proposedBindings in
            PluginActionShortcutPresetPreview(items: actionIDs.map { actionID in
                PluginActionShortcutPresetPreviewItem(
                    actionID: actionID,
                    currentBinding: state.bindings[actionID],
                    proposedBinding: proposedBindings[actionID]
                )
            })
        }
        plugin.applyActionShortcutPreset = { actionIDs, bindings in
            for actionID in actionIDs {
                state.bindings[actionID] = bindings[actionID]
            }
            return nil
        }
        plugin.performActionShortcutReplacementTransaction = {
            actionIDs, bindings, mutation in
            let snapshot = state.bindings
            for actionID in actionIDs {
                state.bindings[actionID] = bindings[actionID]
            }
            if let error = mutation() {
                state.bindings = snapshot
                return error
            }
            return nil
        }
    }
}

@MainActor
private final class MockWindowModifierDragSession: WindowModifierDragSessionManaging {
    var onFailure: (WindowLayoutError) -> Void = { _ in }
    var onSuccess: () -> Void = {}
    private(set) var configuredModifiers: ShortcutModifiers?
    private(set) var configuredShowsIndicator: Bool?
    private(set) var configureCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false
    var startResult: Result<Void, WindowModifierDragMonitorStartError> = .success(())
    var centeredGuidesEnabled = false
    var modifierDragEnabled = false

    func configureFeatures(modifierDragEnabled: Bool, centeredGuidesEnabled: Bool, respectsStageManager: Bool) {
        self.modifierDragEnabled = modifierDragEnabled
        self.centeredGuidesEnabled = centeredGuidesEnabled
    }

    func configure(modifiers: ShortcutModifiers, showsIndicator: Bool) {
        configureCount += 1
        configuredModifiers = modifiers
        configuredShowsIndicator = showsIndicator
    }

    func configure(modifiers: ShortcutModifiers) {
        configure(modifiers: modifiers, showsIndicator: true)
    }

    func start() -> Result<Void, WindowModifierDragMonitorStartError> {
        startCount += 1
        if case .success = startResult {
            isRunning = true
        }
        return startResult
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

@MainActor
private final class WindowLayoutsShortcutState {
    var bindings: [String: ShortcutBinding]

    init(bindings: [String: ShortcutBinding]) {
        self.bindings = bindings
    }
}

@MainActor
private final class WindowLayoutsTrustState {
    var isTrusted: Bool

    init(isTrusted: Bool) {
        self.isTrusted = isTrusted
    }
}

@MainActor
private final class MockWindowLayoutExecutor: WindowLayoutExecuting {
    struct Execution {
        let operation: WindowLayoutOperation
        let gap: CGFloat
    }

    var validationError: WindowLayoutError?
    var executionError: WindowLayoutError?
    private(set) var validationCallCount = 0
    private(set) var executions: [Execution] = []
    private(set) var customExecutions: [WindowCustomCommand] = []

    func validationError(
        for operation: WindowLayoutOperation,
        options: WindowLayoutExecutionOptions
    ) async -> WindowLayoutError? {
        validationCallCount += 1
        return validationError
    }

    func execute(
        _ operation: WindowLayoutOperation,
        options: WindowLayoutExecutionOptions
    ) async -> Result<Void, WindowLayoutError> {
        executions.append(Execution(operation: operation, gap: options.gap))
        if let executionError {
            return .failure(executionError)
        }
        return .success(())
    }

    func validationError(
        for command: WindowCustomCommand,
        options: WindowLayoutExecutionOptions
    ) async -> WindowLayoutError? {
        validationCallCount += 1
        return validationError
    }

    func execute(
        _ command: WindowCustomCommand,
        options: WindowLayoutExecutionOptions
    ) async -> Result<Void, WindowLayoutError> {
        customExecutions.append(command)
        if let executionError {
            return .failure(executionError)
        }
        return .success(())
    }
}

@MainActor
private final class WindowLayoutsMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var rejectLibraryWrites = false

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        if rejectLibraryWrites, key == "library.v1" { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
