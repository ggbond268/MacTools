import Carbon
import XCTest
import MacToolsPluginKit
@testable import WindowLayoutsPlugin

@MainActor
final class WindowLayoutsPluginTests: XCTestCase {
    func testPublishesEveryRaycastParityActionWithCanonicalSafetyPolicy() {
        let executor = MockWindowLayoutExecutor()
        let plugin = makePlugin(executor: executor)

        XCTAssertEqual(
            plugin.actionDefinitions.map(\.key.actionID),
            WindowLayoutOperation.allCases.map(\.rawValue)
        )
        XCTAssertEqual(plugin.actionDefinitions.count, 36)
        for definition in plugin.actionDefinitions {
            XCTAssertEqual(definition.risk, .safe)
            XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
            XCTAssertEqual(definition.concurrencyPolicy, .serialize)
            XCTAssertEqual(definition.capabilities, [.background, .foregroundInteractive, .cancellable])
            XCTAssertFalse(definition.capabilities.contains(.automatic))
            XCTAssertEqual(
                plugin.permissionRequirementIDs(for: definition.key),
                ["accessibility"]
            )
        }
        XCTAssertTrue(plugin.shortcutDefinitions.isEmpty)
        XCTAssertEqual(
            plugin.actionShortcutSettingsConfiguration.actionIDs.count,
            36
        )
    }

    func testAppIntentsAndRunLinksAreExposed() throws {
        let plugin = makePlugin()
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = ActionReference(key: definition.key)

        XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
        XCTAssertEqual(
            plugin.exposurePolicy(for: reference, on: .appIntents),
            .automatic
        )
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

    func testShortcutPresetAssistantCountsConflictRowsIndividuallyAndBlocksApply() {
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_LeftArrow),
            modifiers: [.control, .option]
        )
        let state = WindowShortcutPresetPreviewState(
            preview: PluginActionShortcutPresetPreview(items: [
                PluginActionShortcutPresetPreviewItem(
                    actionID: WindowLayoutOperation.leftHalf.rawValue,
                    currentBinding: nil,
                    proposedBinding: binding,
                    conflictOwnerDescription: "Existing Action"
                ),
                PluginActionShortcutPresetPreviewItem(
                    actionID: WindowLayoutOperation.rightHalf.rawValue,
                    currentBinding: nil,
                    proposedBinding: binding
                ),
            ])
        )

        XCTAssertEqual(state.changedCount, 2)
        XCTAssertEqual(state.conflictCount, 1)
        XCTAssertFalse(state.canApply)
    }

    func testActionShortcutAssignmentChangePublishesPresetSummaryRefresh() {
        let plugin = makePlugin()
        let initialRevision = plugin.actionShortcutAssignmentRevision

        plugin.actionShortcutAssignmentsDidChange()

        XCTAssertEqual(plugin.actionShortcutAssignmentRevision, initialRevision + 1)
    }

    func testCustomCommandEditorPublishesPreviewShortcutAndHeaderActions() throws {
        let plugin = makePlugin()
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let command = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))

        guard case let .form(sections) = try XCTUnwrap(plugin.settingsPage).body,
              let section = sections.first(where: { $0.id == command.key.actionID }),
              case .custom = section.content
        else {
            return XCTFail("Expected a custom command editor section")
        }

        guard case .edgeToEdge = section.presentation else {
            return XCTFail("Expected edge-to-edge custom editor content")
        }
        XCTAssertNotNil(section.headerAccessory)
        XCTAssertNil(
            plugin.actionShortcutSettingsConfiguration.placementAfterSectionID,
            "The shortcut list should follow every custom layout editor"
        )
    }

    func testCustomCommandShortcutCanBeRecordedAndClearedInline() throws {
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
            for actionID in actionIDs {
                currentBindings[actionID] = bindings[actionID]
            }
            return nil
        }

        XCTAssertNil(plugin.customCommandShortcutBinding(for: id))
        XCTAssertEqual(
            plugin.recordCustomCommandShortcut(binding, for: id),
            .accepted
        )
        XCTAssertEqual(plugin.customCommandShortcutBinding(for: id), binding)

        XCTAssertEqual(plugin.clearCustomCommandShortcut(for: id), .accepted)

        XCTAssertNil(plugin.customCommandShortcutBinding(for: id))
    }

    func testCustomCommandShortcutClearReportsHostFailure() throws {
        let plugin = makePlugin()
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))
        let id = try XCTUnwrap(UUID(uuidString: String(
            definition.key.actionID.dropFirst("custom.".count)
        )))
        plugin.applyActionShortcutPreset = { _, _ in "Shortcut storage failed" }

        XCTAssertEqual(
            plugin.clearCustomCommandShortcut(for: id),
            .rejected("Shortcut storage failed")
        )
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

    func testCustomCommandDeleteFailureRestoresClearedShortcut() throws {
        let storage = WindowLayoutsMemoryStorage()
        let plugin = makePlugin(storage: storage)
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
        storage.rejectLibraryWrites = true

        XCTAssertFalse(plugin.deleteCustomCommand(id))

        XCTAssertEqual(shortcutState.bindings[definition.key.actionID], binding)
        XCTAssertTrue(plugin.actionDefinitions.contains(where: {
            $0.key.actionID == definition.key.actionID
        }))
        XCTAssertNotNil(plugin.customCommandDeletionError)
    }

    func testCustomCommandDeleteFailureUsesTransactionToRestoreEveryShortcut() throws {
        let storage = WindowLayoutsMemoryStorage()
        let plugin = makePlugin(storage: storage)
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))
        let id = try XCTUnwrap(UUID(uuidString: String(
            definition.key.actionID.dropFirst("custom.".count)
        )))
        let originalBindings = [
            ShortcutBinding(
                keyCode: UInt16(kVK_ANSI_L),
                modifiers: [.control, .option]
            ),
            ShortcutBinding(
                keyCode: UInt16(kVK_ANSI_M),
                modifiers: [.control, .option]
            ),
        ]
        var bindings = originalBindings
        plugin.performActionShortcutReplacementTransaction = { _, _, mutation in
            let snapshot = bindings
            bindings = []
            if let error = mutation() {
                bindings = snapshot
                return error
            }
            return nil
        }
        storage.rejectLibraryWrites = true

        XCTAssertFalse(plugin.deleteCustomCommand(id))

        XCTAssertEqual(bindings, originalBindings)
        XCTAssertTrue(plugin.actionDefinitions.contains(where: {
            $0.key.actionID == definition.key.actionID
        }))
    }

    func testCustomCommandShortcutReportsHostValidationConflict() throws {
        let plugin = makePlugin()
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        }))
        let id = try XCTUnwrap(UUID(uuidString: String(
            definition.key.actionID.dropFirst("custom.".count)
        )))
        plugin.applyActionShortcutPreset = { _, _ in "Already assigned" }

        let result = plugin.recordCustomCommandShortcut(
            ShortcutBinding(
                keyCode: UInt16(kVK_ANSI_L),
                modifiers: [.control, .option]
            ),
            for: id
        )

        XCTAssertEqual(result, .rejected("Already assigned"))
    }

    func testCustomCommandPreviewLayoutUsesDimensionsAnchorAndOffsets() {
        let centered = WindowCustomCommand(
            name: "Centered",
            width: .fraction(0.6),
            height: .fraction(0.5),
            anchor: .center
        )
        XCTAssertEqual(
            WindowCustomCommandPreviewLayout(command: centered, gap: 0)
                .windowFrame(in: CGSize(width: 160, height: 100)),
            CGRect(x: 32, y: 25, width: 96, height: 50)
        )

        let offsetTopRight = WindowCustomCommand(
            name: "Offset",
            width: .fraction(0.5),
            height: .fraction(0.4),
            anchor: .topRight,
            offsetX: -144,
            offsetY: 90
        )
        XCTAssertEqual(
            WindowCustomCommandPreviewLayout(command: offsetTopRight, gap: 0)
                .windowFrame(in: CGSize(width: 200, height: 100)),
            CGRect(x: 80, y: 10, width: 100, height: 40)
        )

        var clampedBottomRight = offsetTopRight
        clampedBottomRight.anchor = .bottomRight
        clampedBottomRight.offsetX = 500
        clampedBottomRight.offsetY = 500
        XCTAssertEqual(
            WindowCustomCommandPreviewLayout(command: clampedBottomRight, gap: 0)
                .windowFrame(in: CGSize(width: 200, height: 100)),
            CGRect(x: 100, y: 60, width: 100, height: 40)
        )
    }

    func testCustomCommandPreviewLayoutMatchesExecutionGeometryWithGap() {
        let command = WindowCustomCommand(
            name: "Gap",
            width: .fraction(0.5),
            height: .fraction(0.4),
            anchor: .topLeft,
            offsetX: -50,
            offsetY: -50
        )
        let referenceSize = CGSize(width: 1440, height: 900)
        let expected = WindowLayoutCalculator().customFrame(
            for: command,
            windowFrame: CGRect(x: 288, y: 180, width: 864, height: 540),
            visibleFrame: CGRect(origin: .zero, size: referenceSize),
            gap: 17
        )

        let preview = WindowCustomCommandPreviewLayout(command: command, gap: 17)
            .windowFrame(in: referenceSize)

        XCTAssertEqual(preview, expected)
        XCTAssertNotEqual(
            preview,
            WindowCustomCommandPreviewLayout(command: command, gap: 0)
                .windowFrame(in: referenceSize)
        )
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

    func testChangedSliderValueDoesNotPersistBeforeCommit() async throws {
        let executor = MockWindowLayoutExecutor()
        let plugin = makePlugin(executor: executor)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first(where: {
            $0.reference.key.actionID == WindowLayoutOperation.leftHalf.rawValue
        })?.reference)

        plugin.handleSettingsAction(.setNumber(
            controlID: "gap",
            value: 23,
            phase: .changed
        ))
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

    func testBeginActionSnapshotsExecutionOptions() async throws {
        let executor = MockWindowLayoutExecutor()
        let plugin = makePlugin(executor: executor)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first(where: {
            $0.reference.key.actionID == WindowLayoutOperation.leftHalf.rawValue
        })?.reference)
        plugin.handleSettingsAction(.setNumber(controlID: "gap", value: 17, phase: .committed))
        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))

        plugin.handleSettingsAction(.setNumber(controlID: "gap", value: 3, phase: .committed))
        let result = await handle.result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(executor.executions.last?.gap, 17)
    }

    func testCommandFeedbackIsOptInAndLimitedToHeadlessInteractiveSources() async throws {
        let plugin = makePlugin()
        let definition = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID == WindowLayoutOperation.leftHalf.rawValue
        }))
        let reference = ActionReference(key: definition.key)

        let disabled = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .globalShortcut,
            mode: .foreground
        )).result()
        XCTAssertEqual(disabled, .succeeded())

        plugin.handleSettingsAction(.setBoolean(
            controlID: "shows-command-feedback",
            value: true
        ))

        let shortcut = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .globalShortcut,
            mode: .foreground
        )).result()
        XCTAssertEqual(shortcut, .succeeded(message: definition.title))

        let search = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .unifiedSearch,
            mode: .foreground
        )).result()
        XCTAssertEqual(search, .succeeded())
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

    func testCustomRunLinkPolicyChangeRequestsImmediateSafetyRebuild() throws {
        let plugin = makePlugin()
        plugin.handleSettingsAction(.invoke(controlID: "add-custom"))
        let actionID = try XCTUnwrap(plugin.actionDefinitions.first(where: {
            $0.key.actionID.hasPrefix("custom.")
        })?.key.actionID)
        let id = try XCTUnwrap(UUID(uuidString: String(actionID.dropFirst("custom.".count))))
        var customCommand = try XCTUnwrap(plugin.customCommand(id: id))
        var safetyChangeCount = 0
        plugin.onActionSafetyStateChange = { safetyChangeCount += 1 }

        customCommand.allowExternalInvocation = false
        XCTAssertTrue(plugin.updateCustomCommand(customCommand))

        XCTAssertEqual(safetyChangeCount, 1)
        XCTAssertEqual(
            plugin.actionDefinitions.first(where: { $0.key.actionID == actionID })?
                .externalInvocationPolicy,
            .unavailable
        )
    }

    private func makePlugin(
        executor: MockWindowLayoutExecutor? = nil,
        storage: PluginStorage? = nil,
        accessibilityTrusted: @escaping @MainActor @Sendable () -> Bool = { true }
    ) -> WindowLayoutsPlugin {
        WindowLayoutsPlugin(
            context: PluginRuntimeContext(
                pluginID: "window-layouts",
                storage: storage ?? WindowLayoutsMemoryStorage()
            ),
            executor: executor ?? MockWindowLayoutExecutor(),
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
