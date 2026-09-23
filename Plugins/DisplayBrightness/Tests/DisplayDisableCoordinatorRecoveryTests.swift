import CoreGraphics
import Foundation
import XCTest
import MacToolsPluginKit
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayDisableCoordinatorRecoveryTests: XCTestCase {
    func testTopologyReconcileRestoresBuiltInDisplayAfterExternalDisconnect() {
        let fixture = makeDisabledBuiltInFixture()

        fixture.service.onlineDisplays = [fixture.disabledBuiltIn]
        fixture.coordinator.reconcileTopology()

        XCTAssertEqual(
            fixture.service.setEnabledCalls,
            [.init(displayID: fixture.disabledBuiltIn.id, enabled: true)]
        )
        XCTAssertTrue(fixture.store.records.isEmpty)
    }

    /// A switch-off lasts only for the process that made it: startup restores what a previous
    /// run left off even though the external display that stayed on is still connected.
    func testStartupRestoresDisplayLeftOffByPreviousRun() {
        let fixture = makeDisabledBuiltInFixture()

        fixture.coordinator.restoreAllDisplays()

        XCTAssertEqual(
            fixture.service.setEnabledCalls,
            [.init(displayID: fixture.disabledBuiltIn.id, enabled: true)]
        )
        XCTAssertTrue(fixture.store.records.isEmpty)
    }

    func testStartupSkipsDisplayAlreadyRevertedBySystem() {
        let fixture = makeDisabledBuiltInFixture()
        fixture.service.onlineDisplays = fixture.service.onlineDisplays.map {
            $0.withActive(true).withVisibleToAppKit(true)
        }

        fixture.coordinator.restoreAllDisplays()

        XCTAssertTrue(fixture.service.setEnabledCalls.isEmpty)
        XCTAssertTrue(fixture.store.records.isEmpty)
    }

    func testClosedLidDefersBuiltInRestoreUntilLidOpens() {
        let fixture = makeDisabledBuiltInFixture()
        fixture.service.isLidClosed = true

        fixture.service.onlineDisplays = [fixture.disabledBuiltIn]
        fixture.coordinator.reconcileTopology()

        XCTAssertTrue(fixture.service.setEnabledCalls.isEmpty)
        XCTAssertEqual(fixture.store.records.map(\.displayID), [fixture.disabledBuiltIn.id])
        XCTAssertTrue(fixture.lidObserver.isObserving)

        fixture.service.isLidClosed = false
        fixture.lidObserver.simulateLidChange()

        XCTAssertEqual(
            fixture.service.setEnabledCalls,
            [.init(displayID: fixture.disabledBuiltIn.id, enabled: true)]
        )
        XCTAssertTrue(fixture.store.records.isEmpty)
        XCTAssertFalse(fixture.lidObserver.isObserving)
    }

    func testVirtualDisplayDoesNotCountAsRemainingDisplay() async {
        let builtIn = makeDisplay(id: 1, isBuiltin: true)
        let virtual = makeDisplay(id: 5, isVirtual: true)
        let service = FakeDisplayDisableService(onlineDisplays: [builtIn, virtual])
        let store = FakeDisplayDisableStore(records: [])
        let coordinator = makeCoordinator(service: service, store: store)

        XCTAssertEqual(coordinator.snapshot.entries.map(\.id), [builtIn.id])
        XCTAssertEqual(coordinator.snapshot.builtIn?.isDisableAllowed, false)

        await coordinator.disableDisplay(builtIn.id)

        XCTAssertTrue(service.setEnabledCalls.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testExternalDisplayCanBeTurnedOffAndComesBackWhenLastDisplayLeaves() async {
        let builtIn = makeDisplay(id: 1, isBuiltin: true)
        let first = makeDisplay(id: 2, serialNumber: 0x21)
        let second = makeDisplay(id: 3, serialNumber: 0x31)
        let service = FakeDisplayDisableService(onlineDisplays: [builtIn, first, second])
        let store = FakeDisplayDisableStore(records: [])
        let coordinator = makeCoordinator(service: service, store: store)

        await coordinator.disableDisplay(first.id)

        XCTAssertEqual(coordinator.snapshot.entry(for: first.id)?.isDisabled, true)
        XCTAssertEqual(store.records.map(\.displayID), [first.id])
        XCTAssertFalse(coordinator.snapshot.entries.contains { $0.isBuiltin && $0.isDisabled })

        // Losing one of the displays that stayed on keeps the external display off.
        service.onlineDisplays.removeAll { $0.id == second.id }
        coordinator.reconcileTopology()
        XCTAssertEqual(store.records.map(\.displayID), [first.id])

        // Losing all of them brings it back.
        service.onlineDisplays = service.onlineDisplays.map {
            $0.id == builtIn.id ? $0.withActive(false).withVisibleToAppKit(false) : $0
        }
        coordinator.reconcileTopology()

        XCTAssertEqual(service.setEnabledCalls.last, .init(displayID: first.id, enabled: true))
        XCTAssertTrue(store.records.isEmpty)
    }

    func testLastRemainingDisplayCannotBeTurnedOff() async {
        let builtIn = makeDisplay(id: 1, isBuiltin: true)
        let external = makeDisplay(id: 2, serialNumber: 0x21)
        let service = FakeDisplayDisableService(onlineDisplays: [builtIn, external])
        let store = FakeDisplayDisableStore(records: [])
        let coordinator = makeCoordinator(service: service, store: store)

        await coordinator.disableDisplay(builtIn.id)
        await coordinator.disableDisplay(external.id)

        XCTAssertEqual(service.setEnabledCalls, [.init(displayID: builtIn.id, enabled: false)])
        XCTAssertEqual(coordinator.snapshot.entry(for: external.id)?.isDisableAllowed, false)
    }

    func testRestoreAllOnlyTouchesDisplaysTurnedOffByMacTools() {
        // A built-in display switched off by another app is absent from the drawable list and
        // has no record, so cleanup must leave it alone.
        let foreignDisabledBuiltIn = makeDisplay(id: 1, isBuiltin: true, isActive: false)
        let external = makeDisplay(id: 2, serialNumber: 0x21)
        let service = FakeDisplayDisableService(onlineDisplays: [foreignDisabledBuiltIn, external])
        let coordinator = makeCoordinator(service: service, store: FakeDisplayDisableStore(records: []))

        coordinator.restoreAllDisplays()

        XCTAssertTrue(service.setEnabledCalls.isEmpty)
    }

    // MARK: - Fixtures

    private func makeDisabledBuiltInFixture() -> DisabledBuiltInFixture {
        let disabledBuiltIn = makeDisplay(
            id: 1,
            isBuiltin: true,
            isActive: false,
            vendorNumber: 0x610,
            modelNumber: 0xA050,
            serialNumber: 0x01
        )
        let external = makeDisplay(id: 2, vendorNumber: 0x610, modelNumber: 0xA035, serialNumber: 0x99)
        let record = DisplayDisableRecord(
            createdAt: Date(timeIntervalSince1970: 1),
            displayID: disabledBuiltIn.id,
            name: disabledBuiltIn.name,
            isBuiltin: true,
            vendorNumber: disabledBuiltIn.vendorNumber,
            modelNumber: disabledBuiltIn.modelNumber,
            serialNumber: disabledBuiltIn.serialNumber,
            survivorIdentities: [
                DisplaySurvivorIdentity(
                    id: external.id,
                    vendorNumber: external.vendorNumber,
                    modelNumber: external.modelNumber,
                    serialNumber: external.serialNumber
                )
            ]
        )
        let service = FakeDisplayDisableService(onlineDisplays: [disabledBuiltIn, external])
        let store = FakeDisplayDisableStore(records: [record])
        let lidObserver = FakeDisplayLidObserver()
        let coordinator = makeCoordinator(service: service, store: store, lidObserver: lidObserver)

        return DisabledBuiltInFixture(
            disabledBuiltIn: disabledBuiltIn,
            service: service,
            store: store,
            lidObserver: lidObserver,
            coordinator: coordinator
        )
    }

    private func makeCoordinator(
        service: FakeDisplayDisableService,
        store: FakeDisplayDisableStore,
        lidObserver: FakeDisplayLidObserver? = nil
    ) -> DisplayDisableCoordinator {
        DisplayDisableCoordinator(
            service: service,
            store: store,
            lidObserver: lidObserver ?? FakeDisplayLidObserver(),
            verificationSettleDelay: .zero,
            presentationPreparation: {}
        )
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        isBuiltin: Bool = false,
        isActive: Bool = true,
        isVirtual: Bool = false,
        vendorNumber: UInt32? = 0x10AC,
        modelNumber: UInt32? = 0x4242,
        serialNumber: UInt32? = nil
    ) -> DisplayDisableDisplay {
        DisplayDisableDisplay(
            id: id,
            name: isBuiltin ? "Built-in Display" : "Display \(id)",
            isBuiltin: isBuiltin,
            isActive: isActive,
            isInMirrorSet: false,
            isVisibleToAppKit: isActive,
            isVirtual: isVirtual,
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
        )
    }
}

@MainActor
private struct DisabledBuiltInFixture {
    let disabledBuiltIn: DisplayDisableDisplay
    let service: FakeDisplayDisableService
    let store: FakeDisplayDisableStore
    let lidObserver: FakeDisplayLidObserver
    let coordinator: DisplayDisableCoordinator
}

@MainActor
private final class FakeDisplayDisableStore: DisplayDisableStateStoring {
    var records: [DisplayDisableRecord]

    init(records: [DisplayDisableRecord]) {
        self.records = records
    }
}

@MainActor
private final class FakeDisplayLidObserver: DisplayLidObserving {
    private var onChange: (@MainActor () -> Void)?

    var isObserving: Bool { onChange != nil }

    func startObserving(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func stopObserving() {
        onChange = nil
    }

    func simulateLidChange() {
        onChange?()
    }
}

@MainActor
private final class FakeDisplayDisableService: DisplayDisableServicing {
    struct SetEnabledCall: Equatable {
        let displayID: CGDirectDisplayID
        let enabled: Bool
    }

    let isSupported = true
    var isLidClosed: Bool? = false
    var onlineDisplays: [DisplayDisableDisplay]
    private(set) var setEnabledCalls: [SetEnabledCall] = []

    init(onlineDisplays: [DisplayDisableDisplay]) {
        self.onlineDisplays = onlineDisplays
    }

    func listDisplays() -> [DisplayDisableDisplay] {
        onlineDisplays
    }

    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        setEnabledCalls.append(SetEnabledCall(displayID: displayID, enabled: enabled))
        onlineDisplays = onlineDisplays.map { display in
            guard display.id == displayID else { return display }
            return display
                .withActive(enabled)
                .withVisibleToAppKit(enabled)
        }
    }
}
