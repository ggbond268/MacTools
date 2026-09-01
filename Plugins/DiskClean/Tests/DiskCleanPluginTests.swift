import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanPluginTests: XCTestCase {
    func testDeclaresSharedFullDiskAccessRequirement() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        let requirement = try XCTUnwrap(plugin.permissionRequirements.first)
        XCTAssertEqual(requirement.id, "full-disk-access")
        XCTAssertTrue(requirement.description.contains("跳过"))
    }

    func testExpandedPanelExposesOnlyScanCleanAndOpenDetailsActions() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(
            controls.map(\.id),
            [
                DiskCleanPlugin.ControlID.scan,
                DiskCleanPlugin.ControlID.clean,
                DiskCleanPlugin.ControlID.openDetails
            ]
        )
        XCTAssertEqual(controls.map(\.actionTitle), ["扫描", "移到废纸篓", "打开详情"])
        XCTAssertFalse(controls.contains { $0.id.hasPrefix("disk-clean-choice.") })
        XCTAssertFalse(controls.contains { $0.id == "disk-clean-test-mode" })
    }

    // MARK: - P2 section wiring (design §10)

    /// When scan roots change, the new scope must be pushed to the developer-artifact section.
    /// If this wire breaks, users clean with stale results against folders just removed —
    /// the Controller only marks "rescan needed" after receiving the new scope.
    func testAddingPurgeRootUpdatesDeveloperArtifactScope() {
        let purgeRoots = DiskCleanPurgeRootsModel(
            store: DiskCleanPurgeRootsStore(
                persistence: EphemeralPurgeRootsPersistence(),
                resolvePhysicalPath: { $0 }
            )
        )
        let developerArtifacts = DiskCleanController(
            engine: ControlledDiskCleanScanEngine(),
            initialSnapshot: DiskCleanControllerSnapshot(
                phase: .idle,
                scope: .developerArtifacts(roots: []),
                scanResult: nil,
                executionResult: nil,
                isResultStale: false,
                errorMessage: nil
            ),
            removalModeStore: InMemoryDiskCleanRemovalModeStore(mode: .trash)
        )
        _ = DiskCleanPlugin(
            controller: FakeDiskCleanPluginController(),
            developerArtifactsController: developerArtifacts,
            purgeRoots: purgeRoots
        )

        purgeRoots.add("/code")

        XCTAssertEqual(developerArtifacts.snapshot.scope, .developerArtifacts(roots: ["/code"]))
        XCTAssertTrue(developerArtifacts.snapshot.canScan)
    }

    /// Menu bar only reflects the rules section: P2 candidate inflow must not rebuild the host menu.
    func testMenuBarPanelIgnoresSectionControllers() {
        let controller = FakeDiskCleanPluginController()
        let installers = DiskCleanController(
            engine: ControlledDiskCleanScanEngine(),
            removalModeStore: InMemoryDiskCleanRemovalModeStore(mode: .trash)
        )
        let plugin = DiskCleanPlugin(controller: controller, installersController: installers)
        var stateChanges = 0
        plugin.onStateChange = { stateChanges += 1 }

        installers.setScope(.installers)

        XCTAssertEqual(stateChanges, 0)
    }

    func testInvokingScanForwardsToController() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.scan))

        XCTAssertEqual(controller.scanCallCount, 1)
    }

    func testCanonicalActionOpensReviewAndStartsScanWithoutCleaning() async throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
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
        XCTAssertEqual(controller.cleanCallCount, 0)
    }

    /// The panel no longer decides "what to clean": it only forwards commands to the Controller; selection is Controller-owned state.
    func testInvokingCleanForwardsToControllerWithoutComposingItsOwnSelection() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeScannedSnapshot(
            candidates: [
                makePluginTestCandidate(
                    id: "allowed",
                    path: "/Users/tester/Library/Caches/App",
                    sizeResult: .testComplete(bytes: 10)
                )
            ],
            selection: makeSelection(selected: ["allowed"], bytes: 10)
        )

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.clean))

        XCTAssertEqual(controller.cleanCallCount, 1)
    }

    /// Button copy must state how many items and roughly how much, and say what the removal mode will do (design §8.2, §8.4).
    func testCleanActionTitleReportsSelectionAndRemovalMode() throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        let candidates = [
            makePluginTestCandidate(
                id: "a",
                path: "/Users/tester/Library/Caches/App",
                sizeResult: .testComplete(bytes: 5_368_709_120)
            )
        ]

        controller.snapshot = makeScannedSnapshot(
            candidates: candidates,
            selection: makeSelection(selected: ["a"], bytes: 5_368_709_120)
        )
        plugin.handleAction(.setDisclosureExpanded(true))
        let trashTitle = try XCTUnwrap(try cleanControl(of: plugin).actionTitle)
        XCTAssertTrue(trashTitle.hasPrefix("移到废纸篓 · 1 项 · 约"), "actual: \(trashTitle)")
        XCTAssertTrue(trashTitle.contains("GB"), "actual: \(trashTitle)")

        controller.snapshot = makeScannedSnapshot(
            candidates: candidates,
            removalMode: .permanent,
            selection: makeSelection(selected: ["a"], bytes: 5_368_709_120)
        )
        let permanentTitle = try XCTUnwrap(try cleanControl(of: plugin).actionTitle)
        XCTAssertTrue(permanentTitle.hasPrefix("清理 · 1 项 · 约"), "actual: \(permanentTitle)")
    }

    func testCleanIsDisabledWhenNothingIsSelected() throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeScannedSnapshot(
            candidates: [
                makePluginTestCandidate(
                    id: "a",
                    path: "/Users/tester/Library/Caches/App",
                    sizeResult: .testComplete(bytes: 10)
                )
            ],
            selection: makeSelection(selected: [], selectable: ["a"], bytes: 0)
        )

        plugin.handleAction(.setDisclosureExpanded(true))

        XCTAssertEqual(try cleanControl(of: plugin).isEnabled, false)
        XCTAssertEqual(try cleanControl(of: plugin).actionTitle, "移到废纸篓")
    }

    /// "Open Details" must actually switch the settings window; before M4 it was a no-op.
    func testOpenDetailsRequestsConfigurationPresentation() {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())
        var presentationRequests = 0
        plugin.requestSettingsPresentation = { presentationRequests += 1 }

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.openDetails))

        XCTAssertEqual(presentationRequests, 1)
    }

    /// The "(limited)" suffix always derives from limitations, not from happening to scan a protected candidate (design §4.5, §8.2).
    func testPanelSubtitleAppendsLimitedSuffixWhenScanReportsLimitations() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        let candidates = [
            makePluginTestCandidate(
                id: "allowed",
                path: "/Users/tester/Library/Caches/App",
                sizeResult: .testComplete(bytes: 1_024)
            )
        ]

        controller.snapshot = makeScannedSnapshot(candidates: candidates)
        let plain = plugin.primaryPanelState.subtitle

        controller.snapshot = makeScannedSnapshot(
            candidates: candidates,
            limitations: [.fdaRestricted(skippedTargetIDs: ["cache.system"])]
        )
        let limited = plugin.primaryPanelState.subtitle

        XCTAssertFalse(plain.hasSuffix("（受限）"))
        XCTAssertEqual(limited, plain + "（受限）")
    }

    func testPanelDisablesCleanWhenResultExpired() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeScannedSnapshot(
            candidates: [
                makePluginTestCandidate(
                    id: "allowed",
                    path: "/Users/tester/Library/Caches/App",
                    sizeResult: .testComplete(bytes: 10)
                )
            ],
            isResultExpired: true
        )

        plugin.handleAction(.setDisclosureExpanded(true))
        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []

        XCTAssertEqual(controls.first { $0.id == DiskCleanPlugin.ControlID.clean }?.isEnabled, false)
    }

    /// Permanent-delete confirmation: panel swaps to Confirm/Cancel, and Clean must disappear —
    /// the same button must not swing between two meanings.
    func testConfirmingPhaseReplacesCleanActionWithConfirmAndCancel() throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeConfirmingSnapshot(itemCount: 3, totalEstimatedBytes: 5_368_709_120)

        plugin.handleAction(.setDisclosureExpanded(true))
        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(
            controls.map(\.id),
            [
                DiskCleanPlugin.ControlID.scan,
                DiskCleanPlugin.ControlID.confirmClean,
                DiskCleanPlugin.ControlID.cancelClean,
                DiskCleanPlugin.ControlID.openDetails
            ]
        )
        let confirm = try XCTUnwrap(controls.first { $0.id == DiskCleanPlugin.ControlID.confirmClean })
        let confirmTitle = try XCTUnwrap(confirm.actionTitle)
        XCTAssertTrue(confirmTitle.hasPrefix("确认永久清理 3 项 · 约"), "actual: \(confirmTitle)")
        XCTAssertTrue(confirmTitle.contains("GB"), "frozen byte count must appear in the confirmation copy")
    }

    func testConfirmAndCancelActionsForwardToController() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = makeConfirmingSnapshot(itemCount: 1, totalEstimatedBytes: 1_024)

        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.confirmClean))
        plugin.handleAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.cancelClean))

        XCTAssertEqual(controller.confirmCallCount, 1)
        XCTAssertEqual(controller.cancelPendingCallCount, 1)
    }

    /// Trash completion copy must not say "freed": objects still sit in Trash, space is not reclaimed yet (design §7.7).
    func testTrashCompletionSubtitleDoesNotClaimSpaceWasReclaimed() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)
        controller.snapshot = DiskCleanControllerSnapshot(
            phase: .completed,
            scope: .rules(choices: Set(DiskCleanChoice.allCases)),
            scanResult: nil,
            executionResult: DiskCleanExecutionResult(
                itemResults: [
                    DiskCleanExecutionItemResult(
                        candidateID: "a",
                        path: "/cache/a",
                        outcome: .trashed(reclaimedBytes: 1_024, stagedName: ".mactools-staged-a")
                    )
                ],
                mode: .trash
            ),
            isResultStale: false,
            errorMessage: nil
        )

        let subtitle = plugin.primaryPanelState.subtitle
        XCTAssertTrue(subtitle.hasPrefix("已移到废纸篓约"), "actual: \(subtitle)")
        XCTAssertFalse(subtitle.contains("已释放"), "objects in Trash have not truly freed space")
        XCTAssertTrue(subtitle.contains("KB"), "actual: \(subtitle)")
    }

    /// Startup reconciliation must run on activate, or orphan staged objects have no second discovery path.
    func testActivateTriggersStagingReconciliation() async {
        let reconciler = SpyDiskCleanStagingReconciler()
        let storage = URL(fileURLWithPath: "/tmp/diskclean-plugin-activate-test")
        let plugin = DiskCleanPlugin(
            controller: FakeDiskCleanPluginController(),
            storageDirectory: storage,
            reconciler: reconciler
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "disk-clean"))

        await waitUntil("reconciliation was triggered") { !reconciler.reconciledDirectories.isEmpty }
        XCTAssertEqual(reconciler.reconciledDirectories, [storage])
    }

    private func makeConfirmingSnapshot(
        itemCount: Int,
        totalEstimatedBytes: Int64
    ) -> DiskCleanControllerSnapshot {
        DiskCleanControllerSnapshot(
            phase: .confirming,
            scope: .rules(choices: Set(DiskCleanChoice.allCases)),
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            errorMessage: nil,
            removalMode: .permanent,
            pendingPlan: DiskCleanPendingPlanSummary(
                itemCount: itemCount,
                totalEstimatedBytes: totalEstimatedBytes,
                mode: .permanent
            )
        )
    }

    private func cleanControl(of plugin: DiskCleanPlugin) throws -> PluginPanelControl {
        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []
        return try XCTUnwrap(controls.first { $0.id == DiskCleanPlugin.ControlID.clean })
    }

    /// Default-select all cleanable candidates so Clean-button availability is decided by the condition under test, not masked by an empty selection.
    private func makeScannedSnapshot(
        candidates: [DiskCleanCandidate],
        limitations: [DiskCleanScanLimitation] = [],
        isResultExpired: Bool = false,
        removalMode: DiskCleanRemovalMode = .trash,
        selection: DiskCleanSelectionProjection? = nil
    ) -> DiskCleanControllerSnapshot {
        let cleanable = candidates.filter(\.isCleanable)
        let resolvedSelection = selection ?? makeSelection(
            selected: Set(cleanable.map(\.id)),
            bytes: cleanable.reduce(0) { $0 + $1.estimatedBytes }
        )
        return DiskCleanControllerSnapshot(
            phase: .scanned,
            scope: .rules(choices: Set(DiskCleanChoice.allCases)),
            scanResult: DiskCleanScanResult(
                scope: .rules(choices: Set(DiskCleanChoice.allCases)),
                candidates: candidates,
                scannedAt: Date(timeIntervalSince1970: 0),
                limitations: limitations
            ),
            executionResult: nil,
            isResultStale: false,
            isResultExpired: isResultExpired,
            errorMessage: nil,
            removalMode: removalMode,
            selection: resolvedSelection
        )
    }

    private func makeSelection(
        selected: Set<DiskCleanCandidate.ID>,
        selectable: Set<DiskCleanCandidate.ID>? = nil,
        bytes: Int64
    ) -> DiskCleanSelectionProjection {
        DiskCleanSelectionProjection(
            selectedIDs: selected,
            selectableIDs: selectable ?? selected,
            selectedEstimatedBytes: bytes,
            categoryStates: [.appCaches: selected.isEmpty ? .noneSelected : .allSelected]
        )
    }

    private func makePluginTestCandidate(
        id: String,
        path: String,
        safety: DiskCleanSafetyStatus = .allowed,
        sizeResult: DiskCleanSizeResult?
    ) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: id,
            targetID: "cache.rule",
            legacyRuleID: "cache.rule",
            category: .appCaches,
            path: path,
            risk: .low,
            safety: safety,
            sizeResult: sizeResult
        )
    }
}

@MainActor
private final class FakeDiskCleanPluginController: DiskCleanControlling {
    var onStateChange: (() -> Void)?
    var snapshot = DiskCleanControllerSnapshot.initial
    private(set) var scanCallCount = 0
    private(set) var canceledOperationCount = 0
    private(set) var selectedChoiceChanges: [(choice: DiskCleanChoice, isSelected: Bool)] = []
    private(set) var cleanCallCount = 0
    private(set) var confirmCallCount = 0
    private(set) var cancelPendingCallCount = 0
    private(set) var removalModeChanges: [DiskCleanRemovalMode] = []
    private(set) var candidateSelectionChanges: [(id: DiskCleanCandidate.ID, isSelected: Bool)] = []
    private(set) var categorySelectionChanges: [(category: DiskCleanCategoryID, isSelected: Bool)] = []

    private(set) var scopeChanges: [DiskCleanScanScope] = []

    func setScope(_ scope: DiskCleanScanScope) {
        scopeChanges.append(scope)
        snapshot = DiskCleanControllerSnapshot(
            phase: snapshot.phase,
            scope: scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage
        )
        onStateChange?()
    }

    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool) {
        selectedChoiceChanges.append((choice: choice, isSelected: isSelected))
        var nextChoices = snapshot.selectedChoices
        if isSelected {
            nextChoices.insert(choice)
        } else {
            nextChoices.remove(choice)
        }
        setScope(.rules(choices: nextChoices))
    }

    func scan() {
        scanCallCount += 1
        onStateChange?()
    }

    func clean() {
        cleanCallCount += 1
        onStateChange?()
    }

    func setCandidateSelected(_ candidateID: DiskCleanCandidate.ID, isSelected: Bool) {
        candidateSelectionChanges.append((id: candidateID, isSelected: isSelected))
        onStateChange?()
    }

    func setCategorySelection(_ category: DiskCleanCategoryID, isSelected: Bool) {
        categorySelectionChanges.append((category: category, isSelected: isSelected))
        onStateChange?()
    }

    func confirmPendingClean() {
        confirmCallCount += 1
        onStateChange?()
    }

    func cancelPendingClean() {
        cancelPendingCallCount += 1
        onStateChange?()
    }

    func setRemovalMode(_ mode: DiskCleanRemovalMode) {
        removalModeChanges.append(mode)
        onStateChange?()
    }

    func cancelCurrentOperation() {
        canceledOperationCount += 1
        onStateChange?()
    }
}
