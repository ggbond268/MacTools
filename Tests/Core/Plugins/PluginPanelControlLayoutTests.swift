import XCTest
import AppKit
import MacToolsPluginKit
import SwiftUI

/// Frozen source-level replica of the PluginKit v6 public value layout used by
/// plugins built for MacTools 1.3.0. Keep this independent of the production type.
private struct PluginShortcutRecorderV6Layout {
    let title: String
    let displayText: String
    let placeholder: String
    let minWidth: CGFloat
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onBeginRecording: (() -> Void)?
    let onEndRecording: (() -> Void)?
    @State private var isPresented = false
    @State private var isHovered = false
}

private struct PluginSettingsContextV6Layout {
    let pluginID: String
    let shortcutItems: [ShortcutSettingsItem]
    let recordShortcutHandler: (String, ShortcutBinding) -> String?
    let beginShortcutRecordingHandler: (String) -> Void
    let clearShortcutHandler: (String) -> Void
    let resetShortcutHandler: (String) -> Void
}

final class PluginPanelControlLayoutTests: XCTestCase {
    func testControlKindTagsMatchDynamicPluginABI() {
        XCTAssertEqual(tag(of: PluginPanelControlKind.segmented), 0)
        XCTAssertEqual(tag(of: PluginPanelControlKind.datePicker), 1)
        XCTAssertEqual(tag(of: PluginPanelControlKind.selectList), 2)
        XCTAssertEqual(tag(of: PluginPanelControlKind.navigationList), 3)
        XCTAssertEqual(tag(of: PluginPanelControlKind.slider), 4)
        XCTAssertEqual(tag(of: PluginPanelControlKind.actionRow), 5)
        XCTAssertEqual(tag(of: PluginPanelControlKind.switchRow), 6)
    }

    func testStoredPropertyLayoutMatchesDynamicPluginABI() {
        let control = PluginPanelControl(
            id: "demo",
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: "Demo",
            actionIconSystemName: "hammer",
            isEnabled: true
        )

        XCTAssertEqual(
            Mirror(reflecting: control).children.compactMap(\.label),
            [
                "id",
                "kind",
                "options",
                "selectedOptionID",
                "dateValue",
                "minimumDate",
                "displayedComponents",
                "datePickerStyle",
                "sectionTitle",
                "sliderValue",
                "sliderBounds",
                "sliderStep",
                "valueLabel",
                "actionTitle",
                "actionIconSystemName",
                "actionBehavior",
                "showsLeadingDivider",
                "isEnabled",
            ]
        )
    }

    func testShortcutRecorderStoredPropertyLayoutMatchesPluginKitV6ABI() {
        let recorder = PluginShortcutRecorder(
            title: "Shortcut",
            displayText: "",
            onRecord: { _ in .accepted }
        )
        let children = Array(Mirror(reflecting: recorder).children)
        let logicalLabels = children.compactMap(\.label).map { label in
            String(label.drop(while: { $0 == "_" }))
        }

        XCTAssertEqual(
            logicalLabels,
            [
                "title",
                "displayText",
                "placeholder",
                "minWidth",
                "onRecord",
                "onBeginRecording",
                "onEndRecording",
                "isPresented",
                "isHovered",
            ]
        )
        XCTAssertEqual(
            MemoryLayout<PluginShortcutRecorder>.size,
            MemoryLayout<PluginShortcutRecorderV6Layout>.size
        )
        XCTAssertEqual(
            MemoryLayout<PluginShortcutRecorder>.stride,
            MemoryLayout<PluginShortcutRecorderV6Layout>.stride
        )
        XCTAssertEqual(
            MemoryLayout<PluginShortcutRecorder>.alignment,
            MemoryLayout<PluginShortcutRecorderV6Layout>.alignment
        )
    }

    func testSettingsContextStoredPropertyLayoutMatchesPluginKitV6ABI() {
        let context = PluginSettingsContext(pluginID: "test")
        XCTAssertEqual(
            Mirror(reflecting: context).children.compactMap(\.label),
            [
                "pluginID",
                "allShortcutItems",
                "recordShortcutHandler",
                "beginShortcutRecordingHandler",
                "clearShortcutHandler",
                "resetShortcutHandler",
            ]
        )
        XCTAssertEqual(
            MemoryLayout<PluginSettingsContext>.size,
            MemoryLayout<PluginSettingsContextV6Layout>.size
        )
    }

    func testSettingsContextKeepsV6ShortcutsSeparateFromCanonicalActions() {
        let ordinary = ShortcutSettingsItem(
            id: "test.shortcut.open",
            pluginID: "test",
            pluginTitle: "Test",
            title: "Open",
            description: "Open the plugin",
            bindingText: "⌘O",
            isRequired: false,
            canClear: true,
            usesDefaultValue: false,
            errorMessage: nil,
            settingsGroupID: "test.shortcuts"
        )
        let action = PluginSettingsActionShortcutItem(
            actionID: "run",
            title: "Run",
            description: "Run the action",
            bindingText: "⌘R",
            canAssign: true,
            canClear: true
        )

        let context = PluginSettingsContext(
            pluginID: "test",
            shortcutItems: [ordinary],
            actionShortcutItems: [action]
        )

        XCTAssertEqual(context.shortcutItems.map(\.id), [ordinary.id])
        XCTAssertEqual(context.actionShortcutItems.map(\.actionID), [action.actionID])
    }

    private func tag(of kind: PluginPanelControlKind) -> UInt8 {
        withUnsafeBytes(of: kind) { bytes in
            bytes[0]
        }
    }
}
