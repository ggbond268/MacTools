import SwiftUI
import XCTest
import MacToolsPluginKit

final class PluginSettingsModelsTests: XCTestCase {
    func testValidatorAcceptsDeclarativeRowsAndPlacedShortcutGroup() throws {
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "behavior",
                    rows: [
                        PluginSettingsRow(
                            id: "mode",
                            title: "模式",
                            control: .picker(
                                selectionID: "automatic",
                                options: [
                                    PluginSettingsOption(id: "automatic", title: "自动"),
                                    PluginSettingsOption(id: "manual", title: "手动")
                                ],
                                style: .menu
                            )
                        ),
                        PluginSettingsRow(
                            id: "visible-mode",
                            title: "显示模式",
                            control: .choiceGroup(
                                selectionID: "automatic",
                                options: [
                                    PluginSettingsOption(id: "automatic", title: "自动"),
                                    PluginSettingsOption(id: "manual", title: "手动")
                                ]
                            )
                        ),
                        PluginSettingsRow(
                            id: "level",
                            title: "级别",
                            control: .slider(
                                value: 50,
                                range: 0...100,
                                step: 1,
                                valueFormat: .percentage
                            )
                        )
                    ]
                ),
                .shortcutGroup("devices", title: "设备快捷键")
            ]
        )

        XCTAssertNoThrow(
            try PluginSettingsValidator.validate(
                page,
                availableShortcutGroupIDs: ["devices"]
            )
        )
    }

    func testValidatorRejectsDuplicateStableIDs() {
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "first",
                    rows: [row(id: "duplicate")]
                ),
                PluginSettingsSection(
                    id: "second",
                    rows: [row(id: "duplicate")]
                )
            ]
        )

        XCTAssertThrowsError(try PluginSettingsValidator.validate(page)) { error in
            XCTAssertEqual(error as? PluginSettingsValidationError, .duplicateRowID("duplicate"))
        }
    }

    func testValidatorRejectsInvalidPickerSelectionAndSlider() {
        let missingSelection = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "picker",
                    rows: [
                        PluginSettingsRow(
                            id: "mode",
                            title: "模式",
                            control: .picker(
                                selectionID: "missing",
                                options: [PluginSettingsOption(id: "automatic", title: "自动")],
                                style: .automatic
                            )
                        )
                    ]
                )
            ]
        )
        let invalidSlider = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "slider",
                    rows: [
                        PluginSettingsRow(
                            id: "level",
                            title: "级别",
                            control: .slider(
                                value: 101,
                                range: 0...100,
                                step: 0,
                                valueFormat: nil
                            )
                        )
                    ]
                )
            ]
        )

        XCTAssertThrowsError(try PluginSettingsValidator.validate(missingSelection)) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .missingPickerSelection(rowID: "mode", selectionID: "missing")
            )
        }
        XCTAssertThrowsError(try PluginSettingsValidator.validate(invalidSlider)) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .sliderValueOutOfRange(rowID: "level")
            )
        }
    }

    func testValidatorRejectsMissingOrDuplicatedEmbeddedShortcutGroups() {
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "custom",
                    embeddedShortcutGroupIDs: ["devices"]
                ) { _ in
                    EmptyView()
                },
                .shortcutGroup("devices")
            ]
        )

        XCTAssertThrowsError(
            try PluginSettingsValidator.validate(
                page,
                availableShortcutGroupIDs: ["devices"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .duplicateShortcutGroupID("devices")
            )
        }

        let missing = PluginSettingsPage.form(sections: [.shortcutGroup("missing")])
        XCTAssertThrowsError(try PluginSettingsValidator.validate(missing)) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .missingShortcutGroup("missing")
            )
        }
    }

    private func row(id: String) -> PluginSettingsRow {
        PluginSettingsRow(id: id, title: id, control: .toggle(isOn: false))
    }

}
