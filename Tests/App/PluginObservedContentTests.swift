import Combine
import AppKit
import SwiftUI
import XCTest
@testable import MacToolsPluginKit

@MainActor
final class PluginObservedContentTests: XCTestCase {
    func testRetainedViewStopsRenderingHiddenValuesAndReopensWithItsState() async throws {
        let source = Source()
        let log = RenderLog()
        let hosting = NSHostingView(rootView: Root(source: source, log: log, visible: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        try await waitUntil { !log.values.isEmpty }
        source.value = 1
        try await waitUntil { log.values.last == 1 }
        hosting.rootView = Root(source: source, log: log, visible: false)
        try await Task.sleep(for: .milliseconds(100))
        let hiddenRenderCount = log.values.count
        for value in 2...30 { source.value = value }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.values.count, hiddenRenderCount)
        hosting.rootView = Root(source: source, log: log, visible: true)
        try await waitUntil { log.values.last == 30 }
        XCTAssertEqual(log.identities.count, 1, "Visibility changes must preserve local view state")
    }

    func testHiddenPresentationDoesNotPublishAndReopeningCatchesUp() {
        let source = Source()
        let presentation = PluginPresentationObservation()
        var changes = 0
        let subscription = presentation.objectWillChange.sink { changes += 1 }
        presentation.observe(source, isVisible: false)
        for value in 1...50 { source.value = value }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(source.value, 50)

        presentation.observe(source, isVisible: true)
        XCTAssertEqual(changes, 1)
        presentation.observe(source, isVisible: true)
        XCTAssertEqual(changes, 1)
        source.value = 51
        XCTAssertEqual(changes, 2)
        presentation.observe(source, isVisible: false)
        source.value = 52
        XCTAssertEqual(changes, 2)
        presentation.observe(source, isVisible: true)
        XCTAssertEqual(changes, 3)
        withExtendedLifetime(subscription) {}
    }

    func testEachPresentationHasIndependentVisibilityAndReleasesOldSource() {
        let first = Source()
        let second = Source()
        let hidden = PluginPresentationObservation()
        let visible = PluginPresentationObservation()
        var hiddenChanges = 0
        var visibleChanges = 0
        let subscriptions = [hidden.objectWillChange.sink { hiddenChanges += 1 },
                             visible.objectWillChange.sink { visibleChanges += 1 }]
        hidden.observe(first, isVisible: false)
        visible.observe(first, isVisible: true)
        first.value = 1
        XCTAssertEqual(hiddenChanges, 0)
        XCTAssertEqual(visibleChanges, 2)
        visible.observe(second, isVisible: true)
        first.value = 2
        XCTAssertEqual(visibleChanges, 3)
        second.value = 1
        XCTAssertEqual(visibleChanges, 4)
        visible.disconnect()
        second.value = 2
        XCTAssertEqual(visibleChanges, 4)
        withExtendedLifetime(subscriptions) {}
    }

    private final class Source: ObservableObject {
        @Published var value = 0
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private final class RenderLog {
        var values: [Int] = []
        var identities: Set<UUID> = []
        func record(_ value: Int, identity: UUID) { values.append(value); identities.insert(identity) }
    }

    private struct Root: View {
        let source: Source
        let log: RenderLog
        let visible: Bool
        var body: some View {
            PluginObservedContent(source) { source in Probe(value: source.value, log: log) }
                .environment(\.pluginPresentationIsVisible, visible)
        }
    }

    private struct Probe: View {
        let value: Int
        let log: RenderLog
        @State private var identity = UUID()
        var body: some View {
            let _ = log.record(value, identity: identity)
            Text(String(value))
        }
    }
}
