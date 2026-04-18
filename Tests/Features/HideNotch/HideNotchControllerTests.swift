import Foundation
import XCTest
@testable import MacTools

@MainActor
final class HideNotchControllerTests: XCTestCase {
    func testEnableSynchronizesOnlySupportedBuiltinDisplays() async {
        let supportedRecord = makeHideNotchDisplayRecord(
            id: 101,
            displayIdentifier: "BUILTIN-1"
        )
        let externalRecord = makeHideNotchDisplayRecord(
            id: 201,
            displayIdentifier: "EXTERNAL-1",
            name: "Studio Display",
            isBuiltin: false,
            isSupported: false
        )

        let stateStore = InMemoryHideNotchStateStore()
        let maskManager = RecordingHideNotchDesktopMaskManager()
        let controller = HideNotchController(
            displayCatalog: StubHideNotchDisplayCatalog(records: [supportedRecord, externalRecord]),
            maskManager: maskManager,
            stateStore: stateStore,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )

        controller.setEnabled(true)
        await waitUntil {
            !controller.snapshot().isProcessing
        }

        XCTAssertEqual(maskManager.synchronizeCalls.count, 1)
        XCTAssertEqual(
            maskManager.synchronizeCalls.first?.map(\.displayIdentifier),
            ["BUILTIN-1"]
        )
        XCTAssertEqual(controller.snapshot().managedDisplayCount, 1)
        XCTAssertTrue(controller.snapshot().isEnabled)
        XCTAssertTrue(stateStore.desiredEnabled)
    }

    func testDisableHidesAllMasksAndClearsManagedCount() async {
        let supportedRecord = makeHideNotchDisplayRecord(
            id: 102,
            displayIdentifier: "BUILTIN-2"
        )

        let stateStore = InMemoryHideNotchStateStore()
        stateStore.desiredEnabled = true
        let maskManager = RecordingHideNotchDesktopMaskManager()
        maskManager.managedDisplayIdentifiers = ["BUILTIN-2"]

        let controller = HideNotchController(
            displayCatalog: StubHideNotchDisplayCatalog(records: [supportedRecord]),
            maskManager: maskManager,
            stateStore: stateStore,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )

        controller.setEnabled(false)
        await waitUntil {
            !controller.snapshot().isProcessing
        }

        XCTAssertEqual(maskManager.hideAllCallCount, 1)
        XCTAssertEqual(controller.snapshot().managedDisplayCount, 0)
        XCTAssertFalse(controller.snapshot().isEnabled)
        XCTAssertFalse(stateStore.desiredEnabled)
    }

    func testSnapshotShowsAwaitingDisplayWhenEnabledWithoutSupportedDisplay() {
        let stateStore = InMemoryHideNotchStateStore()
        stateStore.desiredEnabled = true

        let controller = HideNotchController(
            displayCatalog: StubHideNotchDisplayCatalog(records: []),
            maskManager: RecordingHideNotchDesktopMaskManager(),
            stateStore: stateStore,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )

        let snapshot = controller.snapshot()
        XCTAssertFalse(snapshot.hasSupportedDisplay)
        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertTrue(snapshot.isAwaitingDisplay)
        XCTAssertEqual(snapshot.managedDisplayCount, 0)
    }

    func testRefreshReconcilesDisplayChangesWhileEnabled() async {
        let initialRecord = makeHideNotchDisplayRecord(
            id: 103,
            displayIdentifier: "BUILTIN-A"
        )
        let nextRecord = makeHideNotchDisplayRecord(
            id: 104,
            displayIdentifier: "BUILTIN-B",
            frame: CGRect(x: 1512, y: 0, width: 1512, height: 982)
        )

        let stateStore = InMemoryHideNotchStateStore()
        let catalog = MutableHideNotchDisplayCatalog(records: [initialRecord])
        let maskManager = RecordingHideNotchDesktopMaskManager()
        let controller = HideNotchController(
            displayCatalog: catalog,
            maskManager: maskManager,
            stateStore: stateStore,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )

        controller.setEnabled(true)
        await waitUntil {
            maskManager.synchronizeCalls.count == 1 && !controller.snapshot().isProcessing
        }

        catalog.records = [initialRecord, nextRecord]
        controller.refresh()
        await waitUntil {
            maskManager.synchronizeCalls.count == 2 && !controller.snapshot().isProcessing
        }

        XCTAssertEqual(
            Set(maskManager.synchronizeCalls.last?.map(\.displayIdentifier) ?? []),
            Set(["BUILTIN-A", "BUILTIN-B"])
        )
        XCTAssertEqual(controller.snapshot().managedDisplayCount, 2)
    }

    func testSyncFailureSurfacesErrorButPreservesEnabledIntent() async {
        struct ForcedError: LocalizedError {
            var errorDescription: String? { "sync failed" }
        }

        let record = makeHideNotchDisplayRecord(
            id: 105,
            displayIdentifier: "BUILTIN-ERR"
        )
        let stateStore = InMemoryHideNotchStateStore()
        let maskManager = RecordingHideNotchDesktopMaskManager()
        maskManager.synchronizeError = ForcedError()

        let controller = HideNotchController(
            displayCatalog: StubHideNotchDisplayCatalog(records: [record]),
            maskManager: maskManager,
            stateStore: stateStore,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )

        controller.setEnabled(true)
        await waitUntil {
            !controller.snapshot().isProcessing
        }

        XCTAssertTrue(controller.snapshot().isEnabled)
        XCTAssertEqual(controller.snapshot().errorMessage, "sync failed")
        XCTAssertEqual(controller.snapshot().managedDisplayCount, 0)
    }
}
