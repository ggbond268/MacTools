import AppKit
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import QuitAppsPlugin

@MainActor
final class QuitAppsPluginTests: XCTestCase {

    // MARK: - Plugin Metadata

    // MARK: - QuitAppsViewModel – invertSelection
    func testInvertSelectionTogglesAllEntries() {
        let vm = QuitAppsViewModel()
        vm.entries = [
            makeEntry(id: "a", isSelected: false),
            makeEntry(id: "b", isSelected: true),
        ]

        vm.invertSelection()

        XCTAssertTrue(vm.entries[0].isSelected)
        XCTAssertFalse(vm.entries[1].isSelected)
    }

    // MARK: - QuitAppsViewModel – toggleEntry

    func testToggleEntryChangesSelectionState() {
        let vm = QuitAppsViewModel()
        vm.entries = [makeEntry(id: "x", isSelected: false)]

        vm.toggleEntry(id: "x")

        XCTAssertTrue(vm.entries[0].isSelected)
    }

    func testLoadExcludesHostApp() {
        let vm = QuitAppsViewModel()
        let host = FakeQuitAppRunningApplication(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "host"
        )

        vm.load(applications: [host])

        let containsHost = vm.entries.contains { $0.id == Bundle.main.bundleIdentifier }
        XCTAssertFalse(containsHost)
    }

    func testLoadPreservesExistingSelection() {
        let vm = QuitAppsViewModel()
        let application = FakeQuitAppRunningApplication(bundleIdentifier: "com.example.app")
        vm.load(applications: [application])

        let first = vm.entries[0]
        vm.toggleEntry(id: first.id)

        vm.load(applications: [application])

        XCTAssertTrue(vm.entries.first { $0.id == first.id }?.isSelected == true)
    }

    func testLoadGroupsMultipleInstancesOfTheSameApplication() {
        let first = FakeQuitAppRunningApplication(
            bundleIdentifier: "com.example.app",
            localizedName: "Example"
        )
        let second = FakeQuitAppRunningApplication(
            bundleIdentifier: "com.example.app",
            localizedName: "Example"
        )
        let vm = QuitAppsViewModel()

        vm.load(applications: [first, second])

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].id, "com.example.app")
        XCTAssertEqual(vm.entries[0].displayName, "Example")
        XCTAssertEqual(vm.entries[0].applications.count, 2)
    }

    func testLoadExcludesTerminatedAndNonRegularApplications() {
        let terminated = FakeQuitAppRunningApplication(
            bundleIdentifier: "com.example.terminated",
            isTerminated: true
        )
        let accessory = FakeQuitAppRunningApplication(
            activationPolicy: .accessory,
            bundleIdentifier: "com.example.accessory"
        )
        let running = FakeQuitAppRunningApplication(bundleIdentifier: "com.example.running")
        let vm = QuitAppsViewModel()

        vm.load(applications: [terminated, accessory, running])

        XCTAssertEqual(vm.entries.map(\.id), ["com.example.running"])
    }

    func testConfirmQuitTerminatesEveryInstanceInSelectedApplication() {
        let first = FakeQuitAppRunningApplication(bundleIdentifier: "com.example.selected")
        let second = FakeQuitAppRunningApplication(bundleIdentifier: "com.example.selected")
        let unselected = FakeQuitAppRunningApplication(bundleIdentifier: "com.example.other")
        let vm = QuitAppsViewModel()
        vm.load(applications: [first, second, unselected])
        vm.toggleEntry(id: "com.example.selected")
        var didFinish = false

        vm.confirmQuit { didFinish = true }

        XCTAssertEqual(first.terminateCallCount, 1)
        XCTAssertEqual(second.terminateCallCount, 1)
        XCTAssertEqual(unselected.terminateCallCount, 0)
        XCTAssertTrue(didFinish)
    }

    func testCatalogProducesUniqueIDsAndStableOrdering() {
        let second = FakeQuitAppRunningApplication(
            bundleIdentifier: "com.example.second",
            localizedName: "Same Name"
        )
        let first = FakeQuitAppRunningApplication(
            bundleIdentifier: "com.example.first",
            localizedName: "Same Name"
        )
        let duplicate = FakeQuitAppRunningApplication(
            bundleIdentifier: "com.example.first",
            localizedName: "Same Name"
        )

        let groups = QuitAppsApplicationCatalog.groups(
            from: [second, first, duplicate],
            excludingBundleIdentifier: nil
        )

        XCTAssertEqual(groups.map(\.id), ["com.example.first", "com.example.second"])
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        XCTAssertEqual(
            QuitAppsApplicationCatalog.applicationCount(
                from: [second, first, duplicate],
                excludingBundleIdentifier: nil
            ),
            2
        )
    }

    func testCanonicalActionOpensTheInteractiveAppChooser() async throws {
        var presentationCount = 0
        let plugin = QuitAppsPlugin(
            runningAppCountProvider: { 2 },
            selectionPresenter: { presentationCount += 1 }
        )
        plugin.refresh()
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(presentationCount, 1)
    }

    func testCanonicalActionIsUnavailableWithoutRunningApps() throws {
        let plugin = QuitAppsPlugin(runningAppCountProvider: { 0 })
        plugin.refresh()
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    private func makeEntry(id: String, isSelected: Bool) -> QuitAppEntry {
        QuitAppEntry(
            group: QuitAppGroup(
                id: id,
                displayName: id,
                icon: nil,
                applications: [FakeQuitAppRunningApplication(bundleIdentifier: id)]
            ),
            isSelected: isSelected
        )
    }
}

private final class FakeQuitAppRunningApplication: QuitAppRunningApplication {
    let activationPolicy: NSApplication.ActivationPolicy
    let bundleIdentifier: String?
    let localizedName: String?
    let icon: NSImage?
    var isTerminated: Bool
    private(set) var terminateCallCount = 0

    init(
        activationPolicy: NSApplication.ActivationPolicy = .regular,
        bundleIdentifier: String?,
        localizedName: String? = "Example",
        icon: NSImage? = nil,
        isTerminated: Bool = false
    ) {
        self.activationPolicy = activationPolicy
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.icon = icon
        self.isTerminated = isTerminated
    }

    func terminate() -> Bool {
        terminateCallCount += 1
        isTerminated = true
        return true
    }
}
