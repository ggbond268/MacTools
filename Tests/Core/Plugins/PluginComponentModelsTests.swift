import AppKit
import SwiftUI
import XCTest
@testable import MacTools

final class PluginComponentModelsTests: XCTestCase {
    func testComponentSpanAcceptsSupportedSizes() {
        XCTAssertEqual(PluginComponentSpan(width: 1, height: 1), .oneByOne)
        XCTAssertEqual(PluginComponentSpan(width: 1, height: 2), .oneByTwo)
        XCTAssertEqual(PluginComponentSpan(width: 2, height: 1), .twoByOne)
        XCTAssertEqual(PluginComponentSpan(width: 2, height: 2), .twoByTwo)
        XCTAssertEqual(PluginComponentSpan(width: 4, height: 2), .fourByTwo)
        XCTAssertEqual(PluginComponentSpan(width: 2, height: 4)?.height, 4)
    }

    func testComponentSpanRejectsUnsupportedSizes() {
        XCTAssertNil(PluginComponentSpan(width: 0, height: 1))
        XCTAssertNil(PluginComponentSpan(width: 5, height: 1))
        XCTAssertNil(PluginComponentSpan(width: 1, height: 0))
    }

    func testPluginMetadataDerivesFromFeatureManifest() {
        let manifest = PluginManifest(
            id: "mock-feature",
            title: "Mock Feature",
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            controlStyle: .switch,
            menuActionBehavior: .keepPresented,
            order: 42,
            defaultDescription: "Feature description"
        )

        XCTAssertEqual(manifest.metadata.id, manifest.id)
        XCTAssertEqual(manifest.metadata.title, manifest.title)
        XCTAssertEqual(manifest.metadata.iconName, manifest.iconName)
        XCTAssertEqual(manifest.metadata.order, manifest.order)
        XCTAssertEqual(manifest.metadata.defaultDescription, manifest.defaultDescription)
    }
}
