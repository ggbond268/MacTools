import XCTest
@testable import MacTools

@MainActor
final class DiskCleanPluginTests: XCTestCase {
    func testManifestIdentifiesDiskCleanPlugin() {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        XCTAssertEqual(plugin.manifest.id, "disk-clean")
        XCTAssertEqual(plugin.manifest.title, "磁盘清理")
    }

    func testExpandedPanelExposesThreeSelectedCleanupChoices() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        plugin.handlePanelAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.panelState.detail?.primaryControls)
        let choiceControls = controls.filter { $0.id.hasPrefix(DiskCleanPlugin.ControlID.choicePrefix) }

        XCTAssertEqual(
            choiceControls.map(\.id),
            DiskCleanChoice.allCases.map { DiskCleanPlugin.ControlID.choice($0) }
        )
        XCTAssertEqual(choiceControls.map(\.actionTitle), DiskCleanChoice.allCases.map(\.title))
        XCTAssertEqual(
            choiceControls.map(\.actionIconSystemName),
            Array(repeating: "checkmark.circle.fill", count: DiskCleanChoice.allCases.count)
        )
    }

    func testInvokingScanForwardsToController() {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)

        plugin.handlePanelAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.scan))

        XCTAssertEqual(controller.scanCallCount, 1)
    }

    func testExpandedPanelExposesAndTogglesTestMode() throws {
        let controller = FakeDiskCleanPluginController()
        let plugin = DiskCleanPlugin(controller: controller)

        plugin.handlePanelAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.panelState.detail?.primaryControls)
        let testMode = try XCTUnwrap(
            controls.first { $0.id == DiskCleanPlugin.ControlID.testMode }
        )

        XCTAssertEqual(testMode.actionTitle, "测试模式：只列出文件")
        XCTAssertEqual(testMode.actionIconSystemName, "checkmark.circle.fill")

        plugin.handlePanelAction(.invokeAction(controlID: DiskCleanPlugin.ControlID.testMode))

        XCTAssertEqual(controller.testModeChanges, [false])
    }

    func testOpenDetailsActionUsesMenuBarStableActionID() throws {
        let plugin = DiskCleanPlugin(controller: FakeDiskCleanPluginController())

        plugin.handlePanelAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.panelState.detail?.primaryControls)
        let openDetails = try XCTUnwrap(
            controls.first { $0.id == DiskCleanPlugin.ControlID.openDetails }
        )

        XCTAssertEqual(DiskCleanPlugin.ControlID.openDetails, MenuBarContent.diskCleanOpenDetailsActionID)
        switch openDetails.actionBehavior {
        case .dismissBeforeHandling:
            break
        case .keepPresented:
            XCTFail("Open details action should dismiss the menu before opening the window")
        }
    }

    func testDefaultPluginHostIncludesDiskClean() {
        let host = PluginHost()

        XCTAssertTrue(host.panelItems.contains { $0.id == "disk-clean" })
        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "disk-clean" })
    }
}

@MainActor
private final class FakeDiskCleanPluginController: DiskCleanControlling {
    var onStateChange: (() -> Void)?
    var snapshot = DiskCleanControllerSnapshot.initial
    private(set) var scanCallCount = 0
    private(set) var canceledOperationCount = 0
    private(set) var testModeChanges: [Bool] = []
    private(set) var selectedChoiceChanges: [(choice: DiskCleanChoice, isSelected: Bool)] = []
    private(set) var cleanSelectedCalls: [Set<DiskCleanCandidate.ID>] = []

    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool) {
        selectedChoiceChanges.append((choice: choice, isSelected: isSelected))
        var nextChoices = snapshot.selectedChoices
        if isSelected {
            nextChoices.insert(choice)
        } else {
            nextChoices.remove(choice)
        }
        snapshot = DiskCleanControllerSnapshot(
            phase: snapshot.phase,
            selectedChoices: nextChoices,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isTestModeEnabled: snapshot.isTestModeEnabled,
            isResultStale: snapshot.isResultStale,
            errorMessage: snapshot.errorMessage
        )
        onStateChange?()
    }

    func setTestModeEnabled(_ isEnabled: Bool) {
        testModeChanges.append(isEnabled)
        snapshot = DiskCleanControllerSnapshot(
            phase: snapshot.phase,
            selectedChoices: snapshot.selectedChoices,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isTestModeEnabled: isEnabled,
            isResultStale: snapshot.isResultStale,
            errorMessage: snapshot.errorMessage
        )
        onStateChange?()
    }

    func scan() {
        scanCallCount += 1
        onStateChange?()
    }

    func cleanSelected(candidateIDs: Set<DiskCleanCandidate.ID>) {
        cleanSelectedCalls.append(candidateIDs)
        onStateChange?()
    }

    func cancelCurrentOperation() {
        canceledOperationCount += 1
        onStateChange?()
    }
}
