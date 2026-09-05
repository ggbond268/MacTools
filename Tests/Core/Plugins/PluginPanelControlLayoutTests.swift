import XCTest
import AppKit
import MacToolsPluginKit
import SwiftUI

/// Frozen source-level replica of the PluginKit v5 public value layout used by
/// previously released plugin binaries. Keep this independent of the production type.
private struct PluginShortcutRecorderV5Layout {
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

private struct PluginSettingsContextV5Layout {
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

    func testShortcutRecorderStoredPropertyLayoutMatchesPluginKitV5ABI() {
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
            MemoryLayout<PluginShortcutRecorderV5Layout>.size
        )
        XCTAssertEqual(
            MemoryLayout<PluginShortcutRecorder>.stride,
            MemoryLayout<PluginShortcutRecorderV5Layout>.stride
        )
        XCTAssertEqual(
            MemoryLayout<PluginShortcutRecorder>.alignment,
            MemoryLayout<PluginShortcutRecorderV5Layout>.alignment
        )
    }

    func testSettingsContextStoredPropertyLayoutMatchesPluginKitV5ABI() {
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
            MemoryLayout<PluginSettingsContextV5Layout>.size
        )
    }

    func testSettingsContextKeepsV5ShortcutsSeparateFromCanonicalActions() {
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

    @MainActor
    func testShortcutRecorderFieldKeepsStableHeightWhenDisplayTextScales() {
        let ordinary = NSHostingView(rootView:
            PluginShortcutRecorderField(
                displayText: "⌥ + ⌘ + C",
                isRecording: false,
                minWidth: PluginSettingsTheme.Size.shortcutRecorderWidth
            )
            .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth)
        )
        let long = NSHostingView(rootView:
            PluginShortcutRecorderField(
                displayText: "⌃ + ⌥ + ⇧ + ⌘ + K",
                isRecording: false,
                minWidth: PluginSettingsTheme.Size.shortcutRecorderWidth
            )
            .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth)
        )

        XCTAssertEqual(
            ordinary.fittingSize.height,
            PluginSettingsTheme.Size.controlHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(long.fittingSize.height, ordinary.fittingSize.height, accuracy: 0.5)
    }

    @MainActor
    func testShortcutRecorderControlReservesClearButtonSpaceWhenUnassigned() {
        let assigned = NSHostingView(rootView:
            PluginSettingsShortcutRecorderControl(
                title: "Shortcut",
                displayText: "⌥ + ⌘ + V",
                canClear: true,
                clearTitle: "Clear",
                onRecord: { _ in .accepted },
                onClear: {}
            )
        )
        let unassigned = NSHostingView(rootView:
            PluginSettingsShortcutRecorderControl(
                title: "Shortcut",
                displayText: "",
                canClear: false,
                clearTitle: "Clear",
                onRecord: { _ in .accepted },
                onClear: {}
            )
        )

        XCTAssertEqual(assigned.fittingSize.width, unassigned.fittingSize.width, accuracy: 0.5)
        XCTAssertEqual(assigned.fittingSize.height, unassigned.fittingSize.height, accuracy: 0.5)
    }

    @MainActor
    func testShortcutRecorderFieldUsesCompactHeightForMiniControls() {
        let recorder = NSHostingView(rootView:
            PluginShortcutRecorderField(
                displayText: "⌥ + ⌘ + C",
                isRecording: false,
                minWidth: 60
            )
            .controlSize(.mini)
            .frame(width: 60)
        )

        XCTAssertEqual(recorder.fittingSize.height, 24, accuracy: 0.5)
    }

    @MainActor
    func testCompactShortcutRecorderExpandsBeyondItsMinimumForLongBindings() {
        let short = NSHostingView(rootView:
            PluginShortcutRecorderField(
                displayText: "⌘\u{2009}V",
                isRecording: false,
                minWidth: 60
            )
            .controlSize(.mini)
            .fixedSize(horizontal: true, vertical: false)
        )
        let long = NSHostingView(rootView:
            PluginShortcutRecorderField(
                displayText: "⌃\u{2009}⌥\u{2009}⇧\u{2009}⌘\u{2009}Help",
                isRecording: false,
                minWidth: 60
            )
            .controlSize(.mini)
            .fixedSize(horizontal: true, vertical: false)
        )

        XCTAssertEqual(short.fittingSize.width, 60, accuracy: 0.5)
        XCTAssertGreaterThan(long.fittingSize.width, short.fittingSize.width)
        XCTAssertEqual(long.fittingSize.height, 24, accuracy: 0.5)
    }

    private func tag(of kind: PluginPanelControlKind) -> UInt8 {
        withUnsafeBytes(of: kind) { bytes in
            bytes[0]
        }
    }
}
