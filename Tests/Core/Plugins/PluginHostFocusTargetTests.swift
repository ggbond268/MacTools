import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PluginHostFocusTargetTests: XCTestCase {
    func testInjectsLastExternalApplicationTargetIntoConsumer() {
        let plugin = FocusTargetConsumerPlugin()
        let application = NSRunningApplication.current
        let targetProvider = FixedFocusTargetProvider(application: application)
        let host = makePluginHostForTests(
            plugins: [plugin],
            loadDynamicPluginsOnInit: false,
            focusedApplicationTargetProvider: targetProvider
        )

        let target = plugin.focusedWindowTargetProvider?()
        XCTAssertTrue(target?.application === application)
        XCTAssertEqual(target?.preferredWindowNumber, 42)
        withExtendedLifetime(host) {}
    }
}

@MainActor
private final class FixedFocusTargetProvider: FocusedApplicationTargetProviding {
    let application: NSRunningApplication
    var currentHostWindowProvider: (() -> NSWindow?)?

    init(application: NSRunningApplication) {
        self.application = application
    }

    func captureCurrentTarget() {}

    func target() -> PluginFocusedWindowTarget? {
        PluginFocusedWindowTarget(application: application, preferredWindowNumber: 42)
    }
}

@MainActor
private final class FocusTargetConsumerPlugin: MacToolsPlugin,
    PluginFocusedWindowTargetConsuming
{
    let metadata = PluginMetadata(
        id: "focus-target-test",
        title: "Focus Target",
        iconName: "scope",
        iconTint: .blue,
        order: 0,
        defaultDescription: ""
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var focusedWindowTargetProvider: (() -> PluginFocusedWindowTarget?)?
}
