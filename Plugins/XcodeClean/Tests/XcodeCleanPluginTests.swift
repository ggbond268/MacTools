import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import XcodeCleanPlugin

@MainActor
final class XcodeCleanPluginTests: XCTestCase {
    func testExpandedPanelExposesScanAndCleanControls() throws {
        let plugin = makePlugin()

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.rowState.detail?.primaryControls)
        XCTAssertEqual(
            controls.map(\.id),
            [XcodeCleanPlugin.ControlID.scan, XcodeCleanPlugin.ControlID.clean]
        )
    }

    func testInvokingScanForwardsToController() {
        let controller = FakeXcodeCleanController()
        let plugin = makePlugin(controller: controller)

        plugin.handleAction(.invokeAction(controlID: XcodeCleanPlugin.ControlID.scan))

        XCTAssertEqual(controller.scanCallCount, 1)
    }

    func testCanonicalActionOpensReviewAndStartsScanWithoutCleaning() async throws {
        let controller = FakeXcodeCleanController()
        let plugin = makePlugin(controller: controller)
        var presentationRequests = 0
        plugin.requestSettingsPresentation = { presentationRequests += 1 }
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key.actionID, "scan-and-review")
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(definition.risk, .safe)

        let handle = try plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .actionGrid,
                mode: .foreground
            )
        )

        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(presentationRequests, 1)
        XCTAssertEqual(controller.scanCallCount, 1)
        XCTAssertTrue(controller.cleanSelectedCalls.isEmpty)
    }

    func testInvokingCleanPresentsConfirmationWithCleanableCandidates() {
        let controller = FakeXcodeCleanController()
        let allowedCandidate = XcodeCleanCandidate(
            id: "allowed",
            category: .derivedData,
            path: "/tmp/a",
            sizeBytes: 10,
            safety: .allowed
        )
        let outsideCandidate = XcodeCleanCandidate(
            id: "outside",
            category: .derivedData,
            path: "/tmp/b",
            sizeBytes: 10,
            safety: .outsideAllowedRoot
        )
        controller.snapshot = XcodeCleanSnapshot(
            phase: .scanned,
            selectedCategories: Set(XcodeCleanCategory.allCases),
            scanResult: XcodeCleanScanResult(
                categories: Set(XcodeCleanCategory.allCases),
                candidates: [allowedCandidate, outsideCandidate],
                scannedAt: Date(timeIntervalSince1970: 0)
            ),
            executionResult: nil,
            isResultStale: false,
            isXcodeRunning: false,
            errorMessage: nil
        )
        let presenter = FakeConfirmationPresenter()
        let plugin = makePlugin(controller: controller, confirmationPresenter: presenter)

        plugin.handleAction(.invokeAction(controlID: XcodeCleanPlugin.ControlID.clean))

        XCTAssertEqual(presenter.presentCalls.count, 1)
        XCTAssertEqual(presenter.presentCalls.first?.candidates, [allowedCandidate])
        XCTAssertEqual(controller.cleanSelectedCalls, [])
    }

    func testConfirmationConfirmCallbackForwardsSelectedIDs() {
        let controller = FakeXcodeCleanController()
        controller.snapshot = XcodeCleanSnapshot(
            phase: .scanned,
            selectedCategories: Set(XcodeCleanCategory.allCases),
            scanResult: XcodeCleanScanResult(
                categories: Set(XcodeCleanCategory.allCases),
                candidates: [
                    XcodeCleanCandidate(id: "a", category: .derivedData, path: "/tmp/a", sizeBytes: 1, safety: .allowed),
                    XcodeCleanCandidate(id: "b", category: .archives, path: "/tmp/b", sizeBytes: 2, safety: .allowed)
                ],
                scannedAt: Date(timeIntervalSince1970: 0)
            ),
            executionResult: nil,
            isResultStale: false,
            isXcodeRunning: false,
            errorMessage: nil
        )
        let presenter = FakeConfirmationPresenter()
        let plugin = makePlugin(controller: controller, confirmationPresenter: presenter)

        plugin.handleAction(.invokeAction(controlID: XcodeCleanPlugin.ControlID.clean))
        presenter.presentCalls.first?.onConfirm(["a"])

        XCTAssertEqual(controller.cleanSelectedCalls, [["a"]])
    }

    func testCleanActionDismissesMenuBeforeHandling() throws {
        let plugin = makePlugin()

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.rowState.detail?.primaryControls)
        let clean = try XCTUnwrap(controls.first { $0.id == XcodeCleanPlugin.ControlID.clean })
        switch clean.actionBehavior {
        case .dismissBeforeHandling: break
        case .keepPresented:
            XCTFail("Clean action should dismiss the menu before opening the confirmation window")
        }
    }

    func testDeactivateDismissesAnyActiveConfirmation() {
        let presenter = FakeConfirmationPresenter()
        let plugin = makePlugin(confirmationPresenter: presenter)

        plugin.deactivate(reason: .disabled)

        XCTAssertEqual(presenter.dismissCallCount, 1)
    }

    func testScanButtonDisabledWhenXcodeRunning() throws {
        let controller = FakeXcodeCleanController()
        controller.snapshot = XcodeCleanSnapshot(
            phase: .idle,
            selectedCategories: Set(XcodeCleanCategory.allCases),
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isXcodeRunning: true,
            errorMessage: nil
        )
        let plugin = makePlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        let scan = try XCTUnwrap(
            plugin.rowState.detail?.primaryControls.first { $0.id == XcodeCleanPlugin.ControlID.scan }
        )
        XCTAssertFalse(scan.isEnabled)
    }

    func testConfirmViewModelSelectsAllCleanableByDefault() {
        let candidates = [
            XcodeCleanCandidate(id: "a", category: .derivedData, path: "/tmp/a", sizeBytes: 10, safety: .allowed),
            XcodeCleanCandidate(id: "b", category: .archives, path: "/tmp/b", sizeBytes: 20, safety: .allowed),
            XcodeCleanCandidate(id: "c", category: .derivedData, path: "/tmp/c", sizeBytes: 30, safety: .outsideAllowedRoot)
        ]
        let vm = XcodeCleanConfirmViewModel(candidates: candidates)

        XCTAssertEqual(vm.selectedIDs, ["a", "b"])
        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(vm.selectedSizeBytes, 30)
        XCTAssertTrue(vm.allSelected)
    }

    func testConfirmViewModelToggleAndSectionState() {
        let candidates = [
            XcodeCleanCandidate(id: "a", category: .derivedData, path: "/tmp/a", sizeBytes: 10, safety: .allowed),
            XcodeCleanCandidate(id: "b", category: .derivedData, path: "/tmp/b", sizeBytes: 20, safety: .allowed)
        ]
        let vm = XcodeCleanConfirmViewModel(candidates: candidates)

        vm.toggle(id: "a")
        XCTAssertEqual(vm.sectionState(.derivedData), .partial)

        vm.setSection(.derivedData, selected: false)
        XCTAssertEqual(vm.sectionState(.derivedData), .none)
        XCTAssertEqual(vm.selectedCount, 0)

        vm.toggleAll()
        XCTAssertEqual(vm.sectionState(.derivedData), .all)
        XCTAssertTrue(vm.allSelected)
    }

    // MARK: - Helpers

    private func makePlugin(
        controller: XcodeCleanControlling? = nil,
        runningMonitor: XcodeCleanRunningMonitoring? = nil,
        confirmationPresenter: XcodeCleanConfirmationPresenting? = nil
    ) -> XcodeCleanPlugin {
        XcodeCleanPlugin(
            controller: controller ?? FakeXcodeCleanController(),
            runningMonitor: runningMonitor ?? FakeXcodeCleanRunningMonitor(),
            confirmationPresenter: confirmationPresenter ?? FakeConfirmationPresenter()
        )
    }
}

@MainActor
private final class FakeXcodeCleanController: XcodeCleanControlling {
    var onStateChange: (() -> Void)?
    var snapshot = XcodeCleanSnapshot.initial
    private(set) var scanCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var cleanSelectedCalls: [Set<XcodeCleanCandidate.ID>] = []
    private(set) var categoryChanges: [(category: XcodeCleanCategory, isSelected: Bool)] = []

    func setCategory(_ category: XcodeCleanCategory, isSelected: Bool) {
        categoryChanges.append((category, isSelected))
        onStateChange?()
    }

    func scan() {
        scanCallCount += 1
        onStateChange?()
    }

    func cleanSelected(candidateIDs: Set<XcodeCleanCandidate.ID>) {
        cleanSelectedCalls.append(candidateIDs)
        onStateChange?()
    }

    func cancelCurrentOperation() {
        cancelCallCount += 1
        onStateChange?()
    }

    func updateXcodeRunningState(_ isRunning: Bool) {
        snapshot = XcodeCleanSnapshot(
            phase: snapshot.phase,
            selectedCategories: snapshot.selectedCategories,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isXcodeRunning: isRunning,
            errorMessage: snapshot.errorMessage
        )
        onStateChange?()
    }
}

@MainActor
private final class FakeXcodeCleanRunningMonitor: XcodeCleanRunningMonitoring {
    var isXcodeRunning: Bool = false
    var onStateChange: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func refresh() { refreshCount += 1 }
}

@MainActor
private final class FakeConfirmationPresenter: XcodeCleanConfirmationPresenting {
    struct PresentCall {
        let candidates: [XcodeCleanCandidate]
        let anchorRect: NSRect?
        let onConfirm: (Set<XcodeCleanCandidate.ID>) -> Void
        let onCancel: () -> Void
    }

    var isPresenting: Bool = false
    private(set) var presentCalls: [PresentCall] = []
    private(set) var dismissCallCount = 0

    func present(
        candidates: [XcodeCleanCandidate],
        anchorRect: NSRect?,
        onConfirm: @escaping (Set<XcodeCleanCandidate.ID>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        presentCalls.append(
            PresentCall(
                candidates: candidates,
                anchorRect: anchorRect,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        )
        isPresenting = true
    }

    func dismiss() {
        dismissCallCount += 1
        isPresenting = false
    }
}
