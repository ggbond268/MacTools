import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PluginShortcutBindingTrackerTests: XCTestCase {
    func testInitialNilChangeAndClearAreDeliveredOnce() {
        let tracker = PluginShortcutBindingTracker(), plugin = BindingTestPlugin()
        let binding = ShortcutBinding(keyCode: 3, modifiers: [.command, .option])
        XCTAssertTrue(tracker.shouldDeliver(to: plugin, shortcutID: "binding", binding: nil))
        XCTAssertFalse(tracker.shouldDeliver(to: plugin, shortcutID: "binding", binding: nil))
        XCTAssertTrue(tracker.shouldDeliver(to: plugin, shortcutID: "binding", binding: binding))
        XCTAssertFalse(tracker.shouldDeliver(to: plugin, shortcutID: "binding", binding: binding))
        XCTAssertTrue(tracker.shouldDeliver(to: plugin, shortcutID: "binding", binding: nil))
    }

    func testReplacementAndReappearingShortcutReceiveInitialState() {
        let tracker = PluginShortcutBindingTracker(), first = BindingTestPlugin(), replacement = BindingTestPlugin()
        XCTAssertTrue(tracker.shouldDeliver(to: first, shortcutID: "binding", binding: nil))
        XCTAssertTrue(tracker.shouldDeliver(to: replacement, shortcutID: "binding", binding: nil))
        tracker.retain(shortcutIDs: [])
        XCTAssertTrue(tracker.shouldDeliver(to: replacement, shortcutID: "binding", binding: nil))
        XCTAssertTrue(tracker.shouldDeliver(to: replacement, shortcutID: "binding", binding: nil, force: true))
    }

    func testTrackerDoesNotRetainUnloadedPlugin() {
        let tracker = PluginShortcutBindingTracker()
        weak var released: BindingTestPlugin?
        do {
            let plugin = BindingTestPlugin()
            released = plugin
            XCTAssertTrue(tracker.shouldDeliver(to: plugin, shortcutID: "binding", binding: nil))
        }
        XCTAssertNil(released)
        XCTAssertTrue(tracker.shouldDeliver(to: BindingTestPlugin(), shortcutID: "binding", binding: nil))
    }
}

@MainActor
private final class BindingTestPlugin: MacToolsPlugin {
    let metadata = PluginMetadata(id: "binding-test", title: "Binding", iconName: "keyboard",
                                  iconTint: .blue, order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
}
