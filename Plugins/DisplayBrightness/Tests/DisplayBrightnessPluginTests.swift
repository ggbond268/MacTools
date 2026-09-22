import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessPluginTests: XCTestCase {

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

}
