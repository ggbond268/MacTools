import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessPluginTests: XCTestCase {
    func testParseDisplayIDExtractsNumericIdentifier() {
        XCTAssertEqual(
            DisplayBrightnessPlugin.parseDisplayID(from: "display.42.brightness"),
            42
        )
    }

    func testParseDisplayIDRejectsUnexpectedControlID() {
        XCTAssertNil(DisplayBrightnessPlugin.parseDisplayID(from: "display.42"))
        XCTAssertNil(DisplayBrightnessPlugin.parseDisplayID(from: "brightness.42"))
        XCTAssertNil(DisplayBrightnessPlugin.parseDisplayID(from: "display.foo.brightness"))
    }

    func testEmptySnapshotDisablesPluginAndSuppressesDetail() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(displays: [], errorMessage: nil)

        let plugin = DisplayBrightnessPlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        let state = plugin.rowState

        XCTAssertEqual(state.subtitle, "未检测到可调节亮度的显示器")
        XCTAssertFalse(state.isEnabled)
        XCTAssertNil(state.detail)
    }

    func testSingleDisplaySummaryIncludesDisplayNameAndBrightness() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)

        XCTAssertEqual(plugin.rowState.subtitle, "Studio Display 72%")
    }

    func testMultipleDisplaysSummaryUsesDisplayCount() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)

        XCTAssertEqual(plugin.rowState.subtitle, "2 个显示器")
    }

    func testExpandedStateBuildsOneSliderPerDisplay() throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.rowState.detail?.primaryControls)
        let sliders = controls.filter { $0.kind == .slider }

        XCTAssertEqual(sliders.count, 2)
        XCTAssertEqual(sliders.map(\.id), ["display.7.brightness", "display.9.brightness"])
        XCTAssertEqual(sliders.map(\.sectionTitle), ["Studio Display", "LG UltraFine"])
        XCTAssertEqual(sliders.map(\.valueLabel), ["72%", "41%"])
        XCTAssertEqual(sliders.first?.sliderBounds, 0...1)
        XCTAssertEqual(sliders.first?.sliderStep, 0.01)
    }

    func testShortcutDefinitionsIncludeDecreaseAndIncreaseOnly() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(
                    id: 7,
                    name: "Studio Display",
                    brightness: 0.72,
                    vendorNumber: 0x610,
                    modelNumber: 32,
                    serialNumber: 9001
                )
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)
        let definitions = plugin.shortcutDefinitions

        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions.map(\.id), ["display-brightness.decrease", "display-brightness.increase"])
        XCTAssertEqual(definitions.map(\.title), ["降低亮度", "增加亮度"])
        XCTAssertEqual(definitions.map(\.description), ["降低显示器亮度。", "增加显示器亮度。"])
        XCTAssertEqual(definitions.map(\.settingsGroupTitle), ["亮度快捷键", "亮度快捷键"])
        XCTAssertEqual(
            definitions.map(\.settingsGroupDescription),
            [
                "按所选作用范围调整显示器亮度。",
                "按所选作用范围调整显示器亮度。"
            ]
        )
        XCTAssertTrue(definitions.allSatisfy { $0.settingsControlTitle == nil })
        XCTAssertEqual(definitions.map(\.settingsControlSystemImage), ["sun.min.fill", "sun.max.fill"])
        XCTAssertEqual(definitions.map(\.settingsGroupID), ["display-brightness.shortcuts", "display-brightness.shortcuts"])
        XCTAssertEqual(definitions.map(\.sharedBindingGroupID), [nil, nil])
        XCTAssertEqual(definitions.map(\.scope), [.global, .global])
    }

    func testDiscreteBrightnessActionUsesConfiguredTargetAndCommits() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)],
            errorMessage: nil
        )
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            mouseDisplayIDProvider: { 7 }
        )
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "display-brightness.increase"
            }?.reference
        )

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.brightnessWrites.map(\.phase), [.ended])
        XCTAssertEqual(controller.brightnessWrites.first?.value ?? 0, 0.73, accuracy: 0.0001)
        let definition = try XCTUnwrap(
            plugin.actionDefinitions.first { $0.key == reference.key }
        )
        XCTAssertTrue(definition.capabilities.contains(.cancellable))
    }

    func testDeactivationCancelsOutstandingControllerWrites() {
        let controller = MockDisplayBrightnessController()
        let plugin = DisplayBrightnessPlugin(controller: controller)

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(controller.cancelOutstandingWritesCount, 1)
    }

    func testDiscreteBrightnessActionReportsBackendFailure() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)],
            errorMessage: nil
        )
        controller.writeResults[7] = .failed(message: "DDC write failed")
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            mouseDisplayIDProvider: { 7 }
        )
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "display-brightness.increase"
            }?.reference
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .failed(message: "DDC write failed"))
        XCTAssertEqual(controller.brightnessWrites.map(\.phase), [.ended])
    }

    func testDiscreteBrightnessActionWaitsForEveryDisplayAndAggregatesFailures() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41),
            ],
            errorMessage: nil
        )
        controller.writeResults[7] = .failed(message: "first failed")
        controller.writeResults[9] = .failed(message: "second failed")
        let preferences = DisplayBrightnessShortcutPreferences(
            storage: DisplayBrightnessMemoryStorage()
        )
        preferences.targetMode = .allDisplays
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences
        )
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "display-brightness.decrease"
            }?.reference
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .failed(message: "first failed；second failed"))
        XCTAssertEqual(controller.brightnessWrites.map(\.displayID), [7, 9])
    }

    func testBuiltInDisplayActionsPublishSafetyAndFollowCoordinatorAvailability() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [makeBrightnessDisplay(id: 7, name: "Built-in", brightness: 0.72)],
            errorMessage: nil
        )
        let coordinator = MockDisplayDisableCoordinator()
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            displayDisableCoordinator: coordinator
        )
        let disable = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "disable-built-in-display"
            }
        )
        let disableDefinition = try XCTUnwrap(
            plugin.actionDefinitions.first { $0.key == disable.reference.key }
        )

        XCTAssertEqual(disableDefinition.risk, .confirmationRequired)
        XCTAssertEqual(disableDefinition.externalInvocationPolicy, .unavailable)
        XCTAssertTrue(disableDefinition.capabilities.contains(.changesDisplayConfiguration))
        XCTAssertTrue(plugin.actionAvailability(for: disable.reference).isAvailable)

        let disableResult = try await plugin.beginAction(
            ActionInvocation(reference: disable.reference, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(disableResult, .succeeded())
        XCTAssertEqual(coordinator.disableCount, 1)

        let restore = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "restore-built-in-display"
            }
        )
        let restoreDefinition = try XCTUnwrap(
            plugin.actionDefinitions.first { $0.key == restore.reference.key }
        )
        XCTAssertTrue(restoreDefinition.capabilities.contains(.changesDisplayConfiguration))
        XCTAssertTrue(plugin.actionAvailability(for: restore.reference).isAvailable)
        let restoreResult = try await plugin.beginAction(
            ActionInvocation(reference: restore.reference, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(restoreResult, .succeeded())
        XCTAssertEqual(coordinator.restoreCount, 1)
    }

    func testShortcutPreferencesDefaultToFollowingMouse() {
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())

        XCTAssertEqual(preferences.targetMode, .followsMouse)
    }

    func testShortcutPreferencesPersistTargetMode() {
        let storage = DisplayBrightnessMemoryStorage()
        let preferences = DisplayBrightnessShortcutPreferences(storage: storage)

        preferences.targetMode = .allDisplays

        XCTAssertEqual(DisplayBrightnessShortcutPreferences(storage: storage).targetMode, .allDisplays)
    }

    func testShortcutDirectionResolvesFixedActionIDs() {
        XCTAssertEqual(
            DisplayBrightnessPlugin.shortcutDirection(for: "display-brightness.decrease"),
            .decrease
        )
        XCTAssertEqual(
            DisplayBrightnessPlugin.shortcutDirection(for: "display-brightness.increase"),
            .increase
        )
        XCTAssertNil(DisplayBrightnessPlugin.shortcutDirection(for: "display-brightness.display.7.increase"))
    }

    func testShortcutFollowingMouseAdjustsOnlyMouseDisplay() throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        preferences.targetMode = .followsMouse
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences,
            mouseDisplayIDProvider: { 9 }
        )

        plugin.handleShortcutEvent(id: "display-brightness.increase", phase: .pressed)

        XCTAssertEqual(controller.brightnessWrites.count, 1)
        let write = try XCTUnwrap(controller.brightnessWrites.first)
        XCTAssertEqual(write.displayID, 9)
        XCTAssertEqual(write.value, 0.42, accuracy: 0.0001)
        XCTAssertEqual(write.phase, .changed)
    }

    func testShortcutAllDisplaysAdjustsEveryDisplay() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        preferences.targetMode = .allDisplays
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences,
            mouseDisplayIDProvider: { 9 }
        )

        plugin.handleShortcutEvent(id: "display-brightness.decrease", phase: .pressed)

        XCTAssertEqual(controller.brightnessWrites.count, 2)
        XCTAssertEqual(controller.brightnessWrites.map(\.displayID), [7, 9])
        XCTAssertEqual(controller.brightnessWrites.map(\.phase), [.changed, .changed])
        XCTAssertEqual(controller.brightnessWrites[0].value, 0.71, accuracy: 0.0001)
        XCTAssertEqual(controller.brightnessWrites[1].value, 0.40, accuracy: 0.0001)
    }

    func testErrorMessageIsExposedFromSnapshot() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)
            ],
            errorMessage: "调节失败：DDC 写入失败"
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)

        XCTAssertEqual(plugin.rowState.errorMessage, "调节失败：DDC 写入失败")
    }
}

@MainActor
private final class MockDisplayDisableCoordinator: DisplayDisableCoordinating {
    var snapshot = DisplayDisableSnapshot(
        status: .available,
        isDisableAllowed: true,
        isRestoreAllowed: false,
        externalDisplayCount: 1,
        message: nil
    )
    private(set) var disableCount = 0
    private(set) var restoreCount = 0

    func refreshSnapshot() {}

    func disableBuiltInDisplay() async {
        disableCount += 1
        snapshot = DisplayDisableSnapshot(
            status: .disabled,
            isDisableAllowed: false,
            isRestoreAllowed: true,
            externalDisplayCount: 1,
            message: nil
        )
    }

    func restoreBuiltInDisplay() {
        restoreCount += 1
        snapshot = DisplayDisableSnapshot(
            status: .available,
            isDisableAllowed: true,
            isRestoreAllowed: false,
            externalDisplayCount: 1,
            message: nil
        )
    }

    func reconcileTopology() async {}
}
