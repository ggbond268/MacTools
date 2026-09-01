import AppKit
import XCTest
@testable import MacTools

final class SettingsSidebarPluginSearchTests: XCTestCase {
    func testMatchesPluginIdentityDescriptionAndExistingKeywords() {
        let values = (
            title: "Display Brightness",
            pluginID: "display-brightness",
            description: "Adjust internal and external displays.",
            keywords: ["DDC", "monitor luminance"]
        )

        for query in [
            "Brightness",
            "display-bright",
            "external displays",
            "DDC",
            "monitor luminance",
            "external DDC",
        ] {
            XCTAssertTrue(
                SettingsSidebarPluginSearchPolicy.matches(
                    query: query,
                    title: values.title,
                    pluginID: values.pluginID,
                    description: values.description,
                    keywords: values.keywords
                ),
                query
            )
        }

        XCTAssertFalse(SettingsSidebarPluginSearchPolicy.matches(
            query: "battery",
            title: values.title,
            pluginID: values.pluginID,
            description: values.description,
            keywords: values.keywords
        ))
    }

    func testMovesResultHighlightAndWrapsAtBothEnds() {
        let destinations: [SettingsNavigationDestination] = [
            .plugins(.configuration("a")),
            .plugins(.configuration("b")),
            .plugins(.configuration("c")),
        ]

        XCTAssertEqual(
            SettingsSidebarPluginSearchPolicy.movedSelection(
                from: nil,
                offset: 1,
                in: destinations
            ),
            destinations.first
        )
        XCTAssertEqual(
            SettingsSidebarPluginSearchPolicy.movedSelection(
                from: nil,
                offset: -1,
                in: destinations
            ),
            destinations.last
        )
        XCTAssertEqual(
            SettingsSidebarPluginSearchPolicy.movedSelection(
                from: destinations.last,
                offset: 1,
                in: destinations
            ),
            destinations.first
        )
        XCTAssertEqual(
            SettingsSidebarPluginSearchPolicy.movedSelection(
                from: destinations.first,
                offset: -1,
                in: destinations
            ),
            destinations.last
        )
    }

    func testPluginFilterFieldMapsNavigationSubmitAndCancelCommands() {
        XCTAssertEqual(
            SettingsSidebarPluginFilterField.command(
                for: #selector(NSResponder.moveDown(_:)),
                hasMarkedText: false
            ),
            .moveSelection(1)
        )
        XCTAssertEqual(
            SettingsSidebarPluginFilterField.command(
                for: #selector(NSResponder.moveUp(_:)),
                hasMarkedText: false
            ),
            .moveSelection(-1)
        )
        XCTAssertEqual(
            SettingsSidebarPluginFilterField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false
            ),
            .submit
        )
        XCTAssertEqual(
            SettingsSidebarPluginFilterField.command(
                for: #selector(NSResponder.cancelOperation(_:)),
                hasMarkedText: false
            ),
            .cancel
        )
        XCTAssertNil(SettingsSidebarPluginFilterField.command(
            for: #selector(NSResponder.moveDown(_:)),
            hasMarkedText: true
        ))
    }

    @MainActor
    func testPluginSearchRevealRunsAfterTheExpansionTurn() async {
        var events = ["expanded"]

        SettingsSidebarPluginSearchRevealScheduler.afterExpansion {
            events.append("revealed")
        }

        XCTAssertEqual(events, ["expanded"])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        XCTAssertEqual(events, ["expanded", "revealed"])
    }
}
