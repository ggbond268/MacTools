import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PanelLayoutToolbarTests: XCTestCase {
    func testPointerClicksEnterEditingAndActivateVisibleDoneButton() async throws {
        let model = MenuBarUnifiedPanelModel(selectedTab: .components, contentHeight: 400,
                                             maximumFeatureListHeight: 400, isPanelVisible: true)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 304, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ToolbarFixture(model: model))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        click(window)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.isEditingLayout)
        click(window)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isEditingLayout)
    }

    private func click(_ window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: 85),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
}

private struct ToolbarFixture: View {
    @ObservedObject var model: MenuBarUnifiedPanelModel

    var body: some View {
        VStack(spacing: 0) {
            MenuBarPanelToolbar(selectedTab: .components, availableUpdateVersion: nil,
                canEditLayout: true, isEditingLayout: model.isEditingLayout, onEditLayout: {
                    if !model.endLayoutEditing() { model.beginLayoutEditing(visibleItemCount: 3) }
                }, onTabSelection: { _ in XCTFail("Edit must not select a tab") },
                onOpenUpdate: {}, onOpenSettings: { XCTFail("Edit must not open Settings") }, onQuit: {})
                .frame(height: 30)
            Spacer()
        }
        .frame(width: 304, height: 100)
    }
}
