import XCTest
import MacToolsPluginKit
@testable import EmptyTrashPlugin

@MainActor
final class EmptyTrashPluginTests: XCTestCase {
    func testRefreshDoesNotCountItemsWhilePrimaryPanelIsHidden() async {
        let counter = TrashCountProbe(itemCount: 3)
        let plugin = EmptyTrashPlugin(
            countItems: { await counter.countItems() },
            countRefreshDelay: .zero
        )

        plugin.refresh()
        await Task.yield()

        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
    }

    func testPrimaryPanelVisibilityRefreshesTrashCount() async {
        let counter = TrashCountProbe(itemCount: 3)
        let plugin = EmptyTrashPlugin(
            countItems: { await counter.countItems() },
            countRefreshDelay: .zero
        )

        plugin.panelSurfaceDidBecomeVisible(.primary)

        await waitForRequestCount(1, counter: counter)
        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "3 个项目")
    }

    func testVisibleCountRefreshesAreDebounced() async {
        let counter = TrashCountProbe(itemCount: 2)
        let plugin = EmptyTrashPlugin(
            countItems: { await counter.countItems() },
            countRefreshDelay: .zero
        )

        plugin.panelSurfaceDidBecomeVisible(.primary)
        plugin.refresh()
        plugin.refresh()

        await waitForRequestCount(1, counter: counter)
        for _ in 0..<5 {
            await Task.yield()
        }

        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, 1)
    }

    func testCanonicalActionCountsAndEmptiesWithoutOpeningThePanel() async throws {
        let counter = TrashCountProbe(itemCount: 3)
        let emptyProbe = TrashEmptyProbe()
        let plugin = EmptyTrashPlugin(
            countItems: { await counter.countItems() },
            emptyItems: { await emptyProbe.empty() },
            countRefreshDelay: .zero
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertFalse(definition.capabilities.contains(.cancellable))
        XCTAssertEqual(definition.executionTimeoutSeconds, 600)
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["automation"])
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: definition.key),
            ["automation"]
        )

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        let emptyCount = await emptyProbe.emptyCount()
        XCTAssertEqual(emptyCount, 1)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "废纸篓为空")
    }

    func testCanonicalActionFailsWhenTrashCannotBeCounted() async throws {
        struct CountFailure: Error {}
        let emptyProbe = TrashEmptyProbe()
        let plugin = EmptyTrashPlugin(
            countItems: { throw CountFailure() },
            emptyItems: { await emptyProbe.empty() },
            countRefreshDelay: .zero
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected count failure, got \(result)")
        }
        let emptyCount = await emptyProbe.emptyCount()
        XCTAssertEqual(emptyCount, 0)
    }

    private func waitForRequestCount(
        _ expectedRequestCount: Int,
        counter: TrashCountProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            if await counter.requestCountValue() == expectedRequestCount {
                return
            }

            await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(50))
        if await counter.requestCountValue() == expectedRequestCount {
            return
        }

        let requestCount = await counter.requestCountValue()
        XCTAssertEqual(requestCount, expectedRequestCount, file: file, line: line)
    }
}

private actor TrashCountProbe {
    private(set) var requestCount = 0
    private let itemCount: Int

    init(itemCount: Int) {
        self.itemCount = itemCount
    }

    func countItems() async -> Int {
        requestCount += 1
        return itemCount
    }

    func requestCountValue() -> Int {
        requestCount
    }
}

private actor TrashEmptyProbe {
    private var count = 0

    func empty() {
        count += 1
    }

    func emptyCount() -> Int {
        count
    }
}
