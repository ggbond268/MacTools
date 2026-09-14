import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PanelLayoutToolbarTests: XCTestCase {
    func testOverflowAlwaysOffersUpdateBeforeQuitAndTracksAvailabilityBadges() async throws {
        var updateCount = 0
        let hosting = NSHostingView(rootView: MenuBarPanelOverflowMenu(canEditLayout: true,
            availableUpdateVersion: nil, onEditLayout: {}, onOpenUpdate: { updateCount += 1 },
            onQuit: { XCTFail("Checking for updates must not quit") }).padding(10))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 48, height: 48),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let capture = PanelToolbarMenuCapture()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu else { return }
                capture.menu = menu
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak menu] timer in
                    MainActor.assumeIsolated {
                        guard let menu else { timer.invalidate(); return }
                        menu.cancelTrackingWithoutAnimation()
                    }
                }
                RunLoop.main.add(timer, forMode: .eventTracking)
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { timer.invalidate() }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for (index, version) in [nil, "1.2.3", nil].enumerated() {
            hosting.rootView = MenuBarPanelOverflowMenu(canEditLayout: true,
                availableUpdateVersion: version, onEditLayout: {}, onOpenUpdate: { updateCount += 1 },
                onQuit: { XCTFail("Checking for updates must not quit") }).padding(10)
            try await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertEqual(containsUpdateBadge(bitmap), version != nil, "The More icon must follow update availability")
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/private/tmp/mactools-update-overflow-\(index).png"))
            capture.menu = nil
            let location = hosting.convert(CGPoint(x: hosting.bounds.midX, y: hosting.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)))
            }
            try await Task.sleep(for: .milliseconds(300))
            let menu = try XCTUnwrap(capture.menu)
            let items = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }
            XCTAssertEqual(items.map(\.title), [PanelLayoutCopy.edit,
                AppL10n.settings("about.update.check", defaultValue: "检查更新"),
                AppL10n.settings("app.quit", defaultValue: "退出")])
            let update = try XCTUnwrap(items.first { $0.title == AppL10n.settings("about.update.check", defaultValue: "检查更新") })
            XCTAssertTrue(update.isEnabled)
            let image = try XCTUnwrap(update.image)
            let badgeBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            XCTAssertEqual(containsUpdateBadge(badgeBitmap), version != nil, "The native menu item must retain the colored badge")
            menu.performActionForItem(at: menu.index(of: update))
            XCTAssertEqual(updateCount, index + 1)
        }
    }

    private func containsUpdateBadge(_ bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.5 && color.redComponent > color.blueComponent + 0.2
                    && color.greenComponent > color.blueComponent + 0.1 { return true }
            }
        }
        return false
    }

    func testEditingFeedbackCoalescesRequestsWithoutDelayingLaterAttempts() {
        let feedback = MenuBarPanelEditingFeedback()
        var count = 0
        let subscription = feedback.requests.sink { count += 1 }
        defer { subscription.cancel() }
        let start = ContinuousClock.now
        feedback.request(at: start)
        feedback.request(at: start.advanced(by: .milliseconds(200)))
        feedback.request(at: start.advanced(by: .milliseconds(599)))
        XCTAssertEqual(count, 1)
        feedback.request(at: start.advanced(by: .milliseconds(600)))
        XCTAssertEqual(count, 2, "Ignored requests must not extend the feedback cooldown")
        feedback.reset()
        feedback.request(at: start.advanced(by: .milliseconds(601)))
        XCTAssertEqual(count, 3, "A new editing session can give feedback immediately")
    }

    func testEditingActionBarPointerClickActivatesVisibleDoneButton() async throws {
        let model = MenuBarUnifiedPanelModel(selectedTab: .components, contentHeight: 400,
                                             maximumFeatureListHeight: 400, isPanelVisible: true)
        model.beginLayoutEditing(visibleItemCount: 3)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 304, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ActionBarFixture(model: model))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        click(window, x: 30)
        XCTAssertTrue(model.isEditingLayout, "The left Undo button must remain disabled")
        click(window, x: 274)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isEditingLayout)
    }

    private func click(_ window: NSWindow, x: CGFloat) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 15),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
}

@MainActor
private final class PanelToolbarMenuCapture {
    var menu: NSMenu?
}

private struct ActionBarFixture: View {
    @ObservedObject var model: MenuBarUnifiedPanelModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            MenuBarPanelEditingActionBar(
                canUndoLayout: false,
                feedback: model.editingFeedback,
                onUndoLayout: { XCTFail("Undo must remain disabled") },
                onDone: { _ = model.endLayoutEditing() }
            )
            .frame(height: MenuBarPanelLayout.editingActionBarHeight)
        }
        .frame(width: 304)
    }
}
