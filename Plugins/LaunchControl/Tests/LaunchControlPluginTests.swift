import XCTest
import MacToolsPluginKit
@testable import LaunchControlPlugin

@MainActor
final class LaunchControlCanonicalActionTests: XCTestCase {
    func testOnlyFavoriteManageableItemsPublishCanonicalActions() throws {
        let favorite = makeItem(id: "favorite", label: "com.example.favorite", isFavorite: true)
        let ordinary = makeItem(id: "ordinary", label: "com.example.ordinary", isFavorite: false)
        let runner = FakeLaunchControlCommandRunner()
        let controller = LaunchControlController(
            runner: runner,
            initialSnapshot: LaunchControlSnapshot(items: [favorite, ordinary])
        )
        let plugin = LaunchControlPlugin(controller: controller)

        XCTAssertEqual(plugin.actionCatalogEntries.count, 3)
        XCTAssertTrue(plugin.actionCatalogEntries.allSatisfy { $0.title.contains(favorite.label) })
        XCTAssertFalse(plugin.actionCatalogEntries.contains { $0.title.contains(ordinary.label) })
        XCTAssertTrue(plugin.actionDefinitions.allSatisfy { definition in
            definition.parameters.first?.portability == .localOnly
                && definition.externalInvocationPolicy == .unavailable
        })
    }

    func testFavoriteStartActionWaitsForLaunchctlResult() async throws {
        let item = makeItem(id: "favorite", label: "com.example.favorite", isFavorite: true)
        let runner = FakeLaunchControlCommandRunner()
        let controller = LaunchControlController(
            runner: runner,
            initialSnapshot: LaunchControlSnapshot(items: [item])
        )
        let plugin = LaunchControlPlugin(controller: controller)
        let entry = try XCTUnwrap(plugin.actionCatalogEntries.first { $0.reference.key.actionID == "start-favorite" })

        let handle = try plugin.beginAction(
            ActionInvocation(reference: entry.reference, source: .actionGrid, mode: .background)
        )

        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(
            try XCTUnwrap(runner.calls.first),
            ["kickstart", "gui/501/\(item.label)"]
        )
    }

    func testOpenManagerRequestsConfigurationPresentation() {
        let plugin = LaunchControlPlugin()
        var requests = 0
        plugin.requestSettingsPresentation = { requests += 1 }

        plugin.handleAction(.invokeAction(controlID: LaunchControlPlugin.ControlID.openManager))

        XCTAssertEqual(requests, 1)
    }

    private func makeItem(id: String, label: String, isFavorite: Bool) -> LaunchControlItem {
        LaunchControlItem(
            id: id,
            label: label,
            plistURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(label).plist"),
            scope: .user,
            origin: .userCreated,
            state: .loaded,
            pid: nil,
            lastExitStatus: 0,
            programArguments: ["/usr/bin/true"],
            runAtLoad: false,
            keepAliveDescription: nil,
            startInterval: nil,
            startCalendarDescription: nil,
            rawPlist: "",
            launchctlDomain: "gui/501",
            isDisabled: false,
            isLoaded: true,
            isFavorite: isFavorite
        )
    }
}

private final class FakeLaunchControlCommandRunner: LaunchControlCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [[String]] = []

    var calls: [[String]] {
        lock.withLock { storedCalls }
    }

    func runLaunchctl(arguments: [String]) throws -> LaunchControlCommandResult {
        lock.withLock { storedCalls.append(arguments) }
        return LaunchControlCommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
