import XCTest
@testable import MacTools

@MainActor
final class AboutUpdateViewModelTests: XCTestCase {
    func testProbeTransitionsToUpToDateState() async {
        let updater = StubUpdater()
        updater.probeResult = .upToDate

        let viewModel = AboutUpdateViewModel(updater: updater)
        await viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.state, .upToDate)
        XCTAssertEqual(
            viewModel.primaryButtonTitle,
            AppL10n.settings("about.update.check", defaultValue: "检查更新")
        )
    }

    func testProbeTransitionsToUpdateAvailableState() async {
        let updater = StubUpdater()
        updater.probeResult = .updateAvailable(version: "0.3.0")

        let viewModel = AboutUpdateViewModel(updater: updater)
        await viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.state, .updateAvailable(version: "0.3.0"))
        XCTAssertEqual(
            viewModel.primaryButtonTitle,
            AppL10n.settings("about.update.installNow", defaultValue: "立即更新")
        )
    }

    func testBlockedInstallPreservesImmediateUpdateAction() async {
        let updater = StubUpdater()
        updater.probeResult = .updateAvailable(version: "0.3.0")
        updater.eligibility = .blocked("请先将应用移到 Applications 再更新。")

        let viewModel = AboutUpdateViewModel(updater: updater)
        await viewModel.performPrimaryAction()
        await viewModel.performPrimaryAction()

        XCTAssertEqual(
            viewModel.state,
            .blocked(reason: "请先将应用移到 Applications 再更新。")
        )
        XCTAssertEqual(
            viewModel.primaryButtonTitle,
            AppL10n.settings("about.update.installNow", defaultValue: "立即更新")
        )
        XCTAssertEqual(updater.checkForUpdatesCallCount, 0)
    }

    func testKnownAvailableUpdateStartsInteractiveFlowWithoutAnotherProbe() async {
        let updater = StubUpdater()
        let viewModel = AboutUpdateViewModel(updater: updater)

        await viewModel.performRequestedUpdateAction(version: "0.3.0")

        XCTAssertEqual(viewModel.state, .updateAvailable(version: "0.3.0"))
        XCTAssertEqual(updater.checkForUpdateInformationCallCount, 0)
        XCTAssertEqual(updater.checkForUpdatesCallCount, 1)
    }

    func testRequestedCheckWithoutKnownVersionProbesInsteadOfReusingAnOldInstallAction() async {
        let updater = StubUpdater()
        let viewModel = AboutUpdateViewModel(updater: updater)
        await viewModel.performRequestedUpdateAction(version: "0.3.0")
        updater.probeResult = .upToDate

        await viewModel.performRequestedUpdateAction(version: nil)

        XCTAssertEqual(viewModel.state, .upToDate)
        XCTAssertEqual(updater.checkForUpdateInformationCallCount, 1)
        XCTAssertEqual(updater.checkForUpdatesCallCount, 1, "A manual check must not repeat the previous install action")
    }

    func testManualCheckUsesKnownAvailabilityWithoutStartingAnotherProbe() async {
        let updater = StubUpdater()
        updater.availableUpdateVersion = "0.3.0"
        let viewModel = AboutUpdateViewModel(updater: updater)

        await viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.state, .updateAvailable(version: "0.3.0"))
        XCTAssertEqual(updater.checkForUpdateInformationCallCount, 0)
        XCTAssertEqual(updater.checkForUpdatesCallCount, 0)
    }

    func testCreatingAboutViewModelDoesNotAutomaticallyCheckOrInstall() {
        let updater = StubUpdater()

        let viewModel = AboutUpdateViewModel(updater: updater)

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(updater.checkForUpdateInformationCallCount, 0)
        XCTAssertEqual(updater.checkForUpdatesCallCount, 0)
    }

    func testStandardUpdateSessionCompletionClearsPanelAvailability() {
        let updater = AppUpdater(startingUpdater: false)
        updater.setAvailableUpdateVersionForTests("0.3.0")

        updater.standardUserDriverWillFinishUpdateSession()

        XCTAssertNil(updater.availableUpdateVersion)
        XCTAssertTrue(updater.supportsGentleScheduledUpdateReminders)
    }

}

@MainActor
private final class StubUpdater: AppUpdating {
    var canCheckForUpdates = true
    var availableUpdateVersion: String?
    var eligibility = UpdateInstallationEligibility.allowed
    var probeResult: AppUpdateProbeResult = .upToDate
    private(set) var checkForUpdateInformationCallCount = 0
    private(set) var checkForUpdatesCallCount = 0

    func installationEligibility() -> UpdateInstallationEligibility {
        eligibility
    }

    func checkForUpdateInformation() async -> AppUpdateProbeResult {
        checkForUpdateInformationCallCount += 1
        return probeResult
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}
