import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistorySettingsAccessibilityTests: XCTestCase {
    func testKeywordExpansionSwitchHasAnAccessibleNameAndCanBeToggled() async throws {
        try await assertNamedSwitch(
            section: .snippets,
            titleKey: "settings.saved.expansion.title",
            fallbackTitle: "Expand Snippet Keywords",
            setting: \.isKeywordExpansionEnabled
        )
    }

    func testHideContentPreviewSwitchHasAnAccessibleNameAndCanBeToggled() async throws {
        try await assertNamedSwitch(
            section: .queue,
            titleKey: "settings.sequentialPaste.hidePreview.title",
            fallbackTitle: "Hide Content Preview",
            setting: \.hidesSequentialHUDPreview
        )
    }

    private func assertNamedSwitch(
        section: ClipboardHistorySettingsContentSection,
        titleKey: String,
        fallbackTitle: String,
        setting: ReferenceWritableKeyPath<ClipboardHistorySettingsStore, Bool>
    ) async throws {
        let settings = ClipboardHistorySettingsStore(storage: AccessibilityTestStorage())
        settings[keyPath: setting] = false
        let pasteboard = AccessibilityTestPasteboard()
        let controller = ClipboardHistoryController(
            settings: settings,
            pasteboard: pasteboard,
            sourceContext: AccessibilityTestSource(),
            persistence: UnavailableClipboardHistoryStore()
        )
        let library = ClipboardSavedLibraryController(
            pasteboard: pasteboard,
            persistence: UnavailableClipboardSavedLibraryStore()
        )
        let localization = PluginLocalization(bundle: Bundle(for: Self.self))
        let title = localization.string(titleKey, defaultValue: fallbackTitle)
        let view = ClipboardHistorySettingsView(
            controller: controller,
            savedLibraryController: library,
            localization: localization,
            contentSections: [section]
        )
        .environment(\.pluginSettingsSearchTarget, PluginSettingsSearchTarget(
            pluginID: ClipboardHistoryPlugin.pluginID,
            entryID: ClipboardHistoryPlugin.ShortcutID.queueGroup
        ))
        .frame(width: 900)
        .fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // AppKit omits actionable SwiftUI accessibility nodes for transparent,
        // mouse-ignoring, or off-screen windows on some macOS/Xcode versions. Order
        // a normal test window so the real accessibility hierarchy and press action
        // are exercised consistently.
        PluginPresentationSafety.prepareForWindowOrdering(window, windows: [window])
        window.orderFrontRegardless()
        defer { window.close() }

        var namedSwitch: AccessibilityTestElement?
        for _ in 0..<100 {
            window.displayIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            namedSwitch = accessibilityElements(in: window).first { element in
                let role = element.role
                guard role == "AXCheckBox" || role == "AXSwitch" else { return false }
                return element.label == title || element.title == title
            }
            if namedSwitch != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let tree = accessibilityElements(in: window).map { element in
            "\(type(of: element.object)): \(element.role ?? "no role") "
                + "label=\(element.label ?? "nil") title=\(element.title ?? "nil") children=\(element.children.count)"
        }.joined(separator: "\n")
        let control = try XCTUnwrap(namedSwitch,
            "The actual settings switch must expose its setting name (\(title)). Accessibility tree:\n\(tree)")
        XCTAssertTrue(control.press())
        for _ in 0..<100 where !settings[keyPath: setting] {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(settings[keyPath: setting], "The named accessible control must remain interactive")
    }

    private func accessibilityElements(in root: Any) -> [AccessibilityTestElement] {
        var visited = Set<ObjectIdentifier>()
        var result: [AccessibilityTestElement] = []
        func visit(_ value: Any) {
            guard let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            let element = AccessibilityTestElement(object: object)
            result.append(element)
            for child in element.children { visit(child) }
        }
        visit(root)
        return result
    }
}

@MainActor
private struct AccessibilityTestElement {
    let object: NSObject
    // SwiftUI's accessibility nodes implement these public selectors without declaring
    // conformance to the complete AppKit protocol. Keep them in the real accessibility tree.
    private var dynamic: AnyObject { object }
    var role: String? { dynamic.accessibilityRole?()?.rawValue }
    var label: String? { dynamic.accessibilityLabel?() }
    var title: String? { dynamic.accessibilityTitle?() }
    var children: [Any] { dynamic.accessibilityChildren?() ?? [] }
    func press() -> Bool {
        dynamic.accessibilityPerformPress?() ?? false
    }
}

@MainActor
private final class AccessibilityTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}

@MainActor
private final class AccessibilityTestPasteboard: ClipboardPasteboardAccess {
    var changeCount: Int { 0 }
    var typeNames: Set<String> { [] }
    func readPlainText() -> String? { nil }
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult { .empty }
    func writePlainText(_ text: String) -> Bool { false }
    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool { false }
}

@MainActor
private final class AccessibilityTestSource: ClipboardSourceContextProviding {
    func frontmostApplication() -> ClipboardSourceApplication? { nil }
}
