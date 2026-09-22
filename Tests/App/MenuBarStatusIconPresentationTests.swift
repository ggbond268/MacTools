import AppKit
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarStatusIconPresentationTests: XCTestCase {
    func testRepeatedUpdatesReuseImageWhileMetadataRemainsLive() {
        let presentation = MenuBarStatusIconPresentation()
        let button = NSButton()
        let image = NSImage(size: NSSize(width: 18, height: 18))
        let key = key(source: .fallback(payload: payload(image), frameIndex: 0))
        var renders = 0

        for _ in 0..<20 {
            XCTAssertTrue(presentation.present(on: button, key: key, tooltip: "Tooltip",
                accessibilityDescription: "Description") { renders += 1; return image })
        }
        presentation.present(on: button, key: key, tooltip: "Localized tooltip",
            accessibilityDescription: "Localized description") { renders += 1; return image }

        XCTAssertEqual(renders, 1)
        XCTAssertTrue(button.image === image)
        XCTAssertEqual(button.toolTip, "Localized tooltip")
        XCTAssertEqual(button.accessibilityLabel(), "Localized description")
    }

    func testRenderingInputsAndStatusItemRecreationInvalidateTheImage() {
        let presentation = MenuBarStatusIconPresentation()
        let button = NSButton()
        let first = NSImage(size: NSSize(width: 18, height: 18))
        let second = NSImage(size: first.size)
        let animated = MenuBarIconImagePayload(image: first, isTemplate: false,
            animationFrames: [first, second], frameDuration: 0.2)
        let generation = UUID()
        let states = [
            key(source: .fallback(payload: payload(first), frameIndex: 0)),
            key(source: .fallback(payload: payload(second), frameIndex: 0)),
            key(source: .fallback(payload: animated, frameIndex: 0)),
            key(source: .fallback(payload: animated, frameIndex: 1)),
            key(source: .fallback(payload: animated, frameIndex: 1), scale: 1),
            key(source: .fallback(payload: animated, frameIndex: 1), appearance: .dark),
            key(source: .fallback(payload: animated, frameIndex: 1), automationCount: 1),
            key(source: .plugin(generation: generation, revision: 1)),
            key(source: .plugin(generation: generation, revision: 2)),
            key(source: .plugin(generation: UUID(), revision: 2)),
            key(source: .fallback(payload: payload(first), frameIndex: 0)),
        ]
        var renders = 0
        for state in states {
            for _ in 0..<2 {
                presentation.present(on: button, key: state, tooltip: "", accessibilityDescription: "") {
                    renders += 1
                    return first
                }
            }
        }
        XCTAssertEqual(renders, states.count)
        presentation.reset()
        presentation.present(on: NSButton(), key: states.last!, tooltip: "", accessibilityDescription: "") {
            renders += 1
            return first
        }
        XCTAssertEqual(renders, states.count + 1)
    }

    func testFailedImageDoesNotPreventRetryOrReplaceExistingPresentation() {
        let presentation = MenuBarStatusIconPresentation()
        let button = NSButton()
        let image = NSImage(size: NSSize(width: 18, height: 18))
        let fallback = key(source: .fallback(payload: payload(image), frameIndex: 0))
        presentation.present(on: button, key: fallback, tooltip: "Fallback", accessibilityDescription: "Fallback") { image }
        let plugin = key(source: .plugin(generation: UUID(), revision: 1))
        XCTAssertFalse(presentation.present(on: button, key: plugin, tooltip: "Plugin", accessibilityDescription: "Plugin") { nil })
        XCTAssertTrue(button.image === image)
        XCTAssertEqual(button.toolTip, "Fallback")
        XCTAssertTrue(presentation.present(on: button, key: plugin, tooltip: "Plugin", accessibilityDescription: "Plugin") { image })
        XCTAssertEqual(button.toolTip, "Plugin")
    }

    private func payload(_ image: NSImage) -> MenuBarIconImagePayload {
        MenuBarIconImagePayload(image: image, isTemplate: true, animationFrames: [], frameDuration: 1)
    }

    private func key(
        source: MenuBarStatusIconPresentation.Key.Source,
        scale: CGFloat = 2,
        appearance: PluginMenuBarIconRenderContext.Appearance = .light,
        automationCount: Int = 0
    ) -> MenuBarStatusIconPresentation.Key {
        .init(source: source, context: .init(pointSize: CGSize(width: 24, height: 24),
                                            displayScale: scale, appearance: appearance),
              runningAutomationCount: automationCount)
    }
}
