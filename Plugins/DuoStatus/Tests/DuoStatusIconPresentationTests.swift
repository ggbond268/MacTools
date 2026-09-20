import AppKit
import MacToolsPluginKit
import XCTest
@testable import DuoStatusPlugin

@MainActor
final class DuoStatusIconPresentationTests: XCTestCase {
    func testRepeatedAppearanceNotificationsKeepTheSameImage() {
        let presentation = DuoStatusIconPresentation()
        let button = NSButton()
        let context = context()
        presentation.update(on: button, snapshot: .unknown, context: context)
        let original = button.image
        XCTAssertNotNil(original)
        for _ in 0..<20 {
            presentation.update(on: button, snapshot: .unknown, context: context)
            XCTAssertTrue(button.image === original)
        }
    }

    func testStatusAppearanceScaleSizeAndRecreationRefreshTheImage() {
        let presentation = DuoStatusIconPresentation()
        let button = NSButton()
        var changed = DuoSystemStatusSnapshot.unknown
        changed.battery = .level(fraction: 0.5, isCharging: true)
        let inputs: [(DuoSystemStatusSnapshot, PluginMenuBarIconRenderContext)] = [
            (.unknown, context()),
            (changed, context()),
            (changed, context(appearance: .dark)),
            (changed, context(appearance: .dark, scale: 1)),
            (changed, context(appearance: .dark, scale: 1, size: 18)),
        ]
        for (snapshot, context) in inputs {
            let previous = button.image
            presentation.update(on: button, snapshot: snapshot, context: context)
            XCTAssertFalse(button.image === previous)
            XCTAssertEqual(button.image?.size, context.pointSize)
            let current = button.image
            presentation.update(on: button, snapshot: snapshot, context: context)
            XCTAssertTrue(button.image === current)
        }
        presentation.reset()
        let replacement = NSButton()
        let last = inputs.last!
        presentation.update(on: replacement, snapshot: last.0, context: last.1)
        XCTAssertNotNil(replacement.image)
    }

    private func context(
        appearance: PluginMenuBarIconRenderContext.Appearance = .light,
        scale: CGFloat = 2,
        size: CGFloat = 24
    ) -> PluginMenuBarIconRenderContext {
        .init(pointSize: NSSize(width: size, height: size), displayScale: scale, appearance: appearance)
    }
}
