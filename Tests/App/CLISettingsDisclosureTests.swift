import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class CLISettingsDisclosureTests: XCTestCase {
    func testLabelAndEmptyRowSpaceToggleEachHeaderWithoutTogglingContent() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let model = DisclosureFixtureModel()
            let view = DisclosureFixture(model: model).environment(\.layoutDirection, direction)
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.orderFront(nil)
            defer { window.close() }
            try await settle()
            // Click the text, then the empty trailing edge, never just the chevron.
            try click("details", model: model, window: window)
            try await settle()
            XCTAssertTrue(model.details)
            let trailingX: CGFloat = direction == .leftToRight ? 340 : 20
            try click("terminal", x: trailingX, model: model, window: window)
            try await settle()
            XCTAssertTrue(model.terminal, "Terminal header did not open in \(direction)")
            XCTAssertTrue(model.details)
            try click("copy", model: model, window: window)
            try await settle()
            XCTAssertEqual(model.copyCount, 1)
            XCTAssertTrue(model.details)
            XCTAssertTrue(model.terminal, "Content controls must not collapse their disclosure")
            try click("terminal", model: model, window: window)
            try await settle()
            XCTAssertFalse(model.terminal)
            try click("details", x: trailingX, model: model, window: window)
            try await settle()
            XCTAssertFalse(model.details)
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    private func click(_ key: String, x: CGFloat? = nil, model: DisclosureFixtureModel, window: NSWindow) throws {
        let frame = try XCTUnwrap(model.frames[key])
        let content = try XCTUnwrap(window.contentView)
        let point = CGPoint(x: x ?? frame.midX, y: content.bounds.height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }
}

@MainActor
private final class DisclosureFixtureModel: ObservableObject {
    @Published var details = false
    @Published var terminal = false
    var copyCount = 0
    var frames: [String: CGRect] = [:]
}

private struct DisclosureFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DisclosureFixture: View {
    @ObservedObject var model: DisclosureFixtureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $model.details) {
                DisclosureGroup(isExpanded: $model.terminal) {
                    Button { model.copyCount += 1 } label: { label("Copy", key: "copy") }
                        .buttonStyle(.bordered)
                } label: { label("Terminal setup", key: "terminal") }
                .disclosureGroupStyle(CLISettingsDisclosureStyle())
            } label: { label("Details", key: "details") }
            Spacer()
        }
        .disclosureGroupStyle(CLISettingsDisclosureStyle())
        .frame(width: 360, height: 260, alignment: .topLeading)
        .coordinateSpace(name: "fixture")
        .onPreferenceChange(DisclosureFrames.self) { model.frames = $0 }
    }

    private func label(_ title: String, key: String) -> some View {
        Text(title).background(GeometryReader { proxy in
            Color.clear.preference(key: DisclosureFrames.self, value: [key: proxy.frame(in: .named("fixture"))])
        })
    }
}
