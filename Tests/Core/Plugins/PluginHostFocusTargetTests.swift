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

    func testUsesOnlyVisibleKeyPluginWindowAsLayoutTarget() {
        let eligibleWindow = FocusTargetTestWindow(isKey: true, isVisible: true)
        let ineligibleWindow = FocusTargetTestWindow(isKey: false, isVisible: true)
        let eligiblePlugin = WindowLayoutTargetPlugin(id: "eligible", window: eligibleWindow)
        let ineligiblePlugin = WindowLayoutTargetPlugin(id: "ineligible", window: ineligibleWindow)
        let host = makePluginHostForTests(
            plugins: [ineligiblePlugin, eligiblePlugin],
            loadDynamicPluginsOnInit: false
        )

        XCTAssertTrue(host.focusedPluginWindowLayoutTarget() === eligibleWindow)
    }

    func testVisibleRegisteredParentIsEligibleWhileItsActionsChildIsKey() {
        let parent = FocusTargetTestWindow(isKey: false, isVisible: true)
        let child = FocusTargetTestWindow(isKey: true, isVisible: true)
        parent.addChildWindow(child, ordered: .above)
        defer { parent.removeChildWindow(child) }
        let host = makePluginHostForTests(plugins: [WindowLayoutTargetPlugin(id: "parent", window: parent)], loadDynamicPluginsOnInit: false)
        XCTAssertTrue(host.focusedPluginWindowLayoutTarget() === parent)
    }

    func testHiddenParentOrHiddenChildNeverConfersLayoutEligibility() {
        for (parentVisible, childVisible) in [(false, true), (true, false)] {
            let parent = FocusTargetTestWindow(isKey: false, isVisible: parentVisible)
            let child = FocusTargetTestWindow(isKey: true, isVisible: childVisible)
            parent.addChildWindow(child, ordered: .above)
            let host = makePluginHostForTests(plugins: [WindowLayoutTargetPlugin(id: "parent", window: parent)], loadDynamicPluginsOnInit: false)
            XCTAssertNil(host.focusedPluginWindowLayoutTarget())
            parent.removeChildWindow(child)
        }
    }
}

private final class FocusTargetTestWindow: NSWindow {
    private let reportedIsKey: Bool
    private let reportedIsVisible: Bool

    init(isKey: Bool, isVisible: Bool) {
        reportedIsKey = isKey
        reportedIsVisible = isVisible
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    override var isKeyWindow: Bool { reportedIsKey }
    override var isVisible: Bool { reportedIsVisible }
}

@MainActor
private final class WindowLayoutTargetPlugin: MacToolsPlugin, PluginWindowLayoutTargetProviding {
    let metadata: PluginMetadata
    let focusedWindowLayoutTarget: NSWindow?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, window: NSWindow?) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "rectangle",
            iconTint: .blue,
            order: 0,
            defaultDescription: ""
        )
        focusedWindowLayoutTarget = window
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
