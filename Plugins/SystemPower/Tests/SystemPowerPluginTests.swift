import XCTest
import MacToolsPluginKit
@testable import SystemPowerPlugin

@MainActor
final class SystemPowerPluginTests: XCTestCase {
    func testManifestActionsMatchRuntimeDefinitions() throws {
        let plugin = makePlugin()

        try PluginManifestActionAssertions.assertConsistency(
            pluginDirectoryName: "SystemPower",
            definitions: plugin.actionDefinitions,
            permissionIDs: plugin.permissionRequirementIDs(for:)
        )
    }

    func testPluginContractAndPanelControls() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "system-power")
        XCTAssertEqual(plugin.metadata.order, 99)
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .disclosure)
        XCTAssertFalse(plugin.primaryPanelState.isExpanded)
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.map(\.id),
            ["sleep", "log-out", "restart", "shut-down"]
        )
        XCTAssertTrue(
            plugin.primaryPanelState.detail?.primaryControls.allSatisfy {
                switch $0.actionBehavior {
                case .dismissBeforeHandling:
                    true
                case .keepPresented:
                    false
                }
            } == true
        )
    }

    func testDisclosureStateNotifiesTheHost() {
        let plugin = makePlugin()
        var stateChangeCount = 0
        plugin.onStateChange = { stateChangeCount += 1 }

        plugin.handleAction(.setDisclosureExpanded(true))

        XCTAssertTrue(plugin.primaryPanelState.isExpanded)
        XCTAssertEqual(stateChangeCount, 1)
    }

    func testCanonicalActionsAreForegroundOnlyAndUnavailableToRunLinks() {
        let plugin = makePlugin()

        XCTAssertEqual(
            plugin.actionDefinitions.map(\.key.actionID),
            ["sleep", "log-out", "restart", "shut-down"]
        )
        for definition in plugin.actionDefinitions {
            XCTAssertEqual(definition.risk, .safe)
            XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
            XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        }
    }

    func testAutomationPermissionIsMappedOnlyToLoginWindowActions() throws {
        let plugin = makePlugin()
        let requirement = try XCTUnwrap(plugin.permissionRequirements.first)

        XCTAssertEqual(requirement.id, "automation")
        XCTAssertEqual(
            plugin.permissionRequirementIDs(
                for: ActionKey(providerID: "system-power", actionID: "sleep")
            ),
            []
        )
        for actionID in ["log-out", "restart", "shut-down"] {
            XCTAssertEqual(
                plugin.permissionRequirementIDs(
                    for: ActionKey(providerID: "system-power", actionID: actionID)
                ),
                ["automation"]
            )
        }
    }

    func testCanonicalActionsDispatchTheRequestedOperation() async throws {
        let recorder = SystemPowerOperationRecorder()
        let plugin = makePlugin { operation in
            recorder.operations.append(operation)
            return .succeeded
        }

        for definition in plugin.actionDefinitions {
            let reference = ActionReference(key: definition.key)
            let result = try await plugin.beginAction(ActionInvocation(
                reference: reference,
                source: .test,
                mode: .foreground
            )).result()
            XCTAssertEqual(result, .succeeded())
        }

        XCTAssertEqual(recorder.operations, SystemPowerOperation.allCases)
    }

    func testFailureIsReportedInThePanelState() async throws {
        let plugin = makePlugin { _ in .failed }
        let reference = ActionReference(
            key: ActionKey(providerID: "system-power", actionID: "restart")
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .foreground
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected the operation to fail, got \(result)")
        }
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testSuccessfulRetryClearsPanelErrorAndNotifiesTheHost() async throws {
        let results = SystemPowerOperationResultSequence([.failed, .succeeded])
        let plugin = makePlugin { _ in results.next() }
        var stateChangeCount = 0
        plugin.onStateChange = { stateChangeCount += 1 }
        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "system-power", actionID: "restart")
            ),
            source: .test,
            mode: .foreground
        )

        let failure = try await plugin.beginAction(invocation).result()
        guard case .failed = failure else {
            return XCTFail("Expected the first operation to fail, got \(failure)")
        }
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        XCTAssertEqual(stateChangeCount, 1)

        let success = try await plugin.beginAction(invocation).result()
        XCTAssertEqual(success, .succeeded())
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
        XCTAssertEqual(stateChangeCount, 2)
    }

    func testAutomationDenialShowsGuidanceAndSuccessfulRetryRestoresPermissionState() async throws {
        let results = SystemPowerOperationResultSequence([
            .automationPermissionDenied,
            .succeeded,
        ])
        let plugin = makePlugin { _ in results.next() }
        var requestedPermissionID: String?
        var stateChangeCount = 0
        plugin.requestPermissionGuidance = { requestedPermissionID = $0 }
        plugin.onStateChange = { stateChangeCount += 1 }
        let reference = ActionReference(
            key: ActionKey(providerID: "system-power", actionID: "shut-down")
        )
        let invocation = ActionInvocation(
            reference: reference,
            source: .test,
            mode: .foreground
        )

        let result = try await plugin.beginAction(invocation).result()

        guard case .failed = result else {
            return XCTFail("Expected the denied operation to fail, got \(result)")
        }
        XCTAssertEqual(requestedPermissionID, "automation")
        XCTAssertFalse(plugin.permissionState(for: "automation").isGranted)
        XCTAssertNotNil(plugin.permissionState(for: "automation").footnote)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
        XCTAssertEqual(stateChangeCount, 1)

        let retryResult = try await plugin.beginAction(invocation).result()

        XCTAssertEqual(retryResult, .succeeded())
        XCTAssertTrue(plugin.permissionState(for: "automation").isGranted)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
        XCTAssertEqual(stateChangeCount, 2)
    }

    private func makePlugin(
        performOperation: @escaping @MainActor @Sendable (SystemPowerOperation) async -> SystemPowerOperationResult = { _ in .succeeded }
    ) -> SystemPowerPlugin {
        SystemPowerPlugin(
            presentationPreparation: {},
            performOperation: performOperation
        )
    }
}

@MainActor
private final class SystemPowerOperationRecorder {
    var operations: [SystemPowerOperation] = []
}

@MainActor
private final class SystemPowerOperationResultSequence {
    private var results: [SystemPowerOperationResult]

    init(_ results: [SystemPowerOperationResult]) {
        self.results = results
    }

    func next() -> SystemPowerOperationResult {
        results.removeFirst()
    }
}
