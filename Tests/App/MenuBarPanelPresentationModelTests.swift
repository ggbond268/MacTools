import Combine
import XCTest
@testable import MacTools

@MainActor
final class MenuBarPanelPresentationModelTests: XCTestCase {
    func testHiddenUpdatesDoNotPublishAndOpeningCatchesUpOnce() {
        let host = makePluginHostForTests(plugins: [])
        let presentation = MenuBarPanelPresentationModel(host: host)
        var publications = 0
        let subscription = presentation.objectWillChange.sink { publications += 1 }

        for _ in 0..<20 { host.menuBarPanelContentDidChange.send() }
        XCTAssertEqual(publications, 0)
        presentation.setVisible(true)
        XCTAssertEqual(publications, 1)
        presentation.setVisible(true)
        XCTAssertEqual(publications, 1)
        host.menuBarPanelContentDidChange.send()
        XCTAssertEqual(publications, 2)
        presentation.setVisible(false)
        for _ in 0..<20 { host.menuBarPanelContentDidChange.send() }
        XCTAssertEqual(publications, 2)
        presentation.setVisible(true)
        XCTAssertEqual(publications, 3)
        withExtendedLifetime(subscription) {}
    }

    func testUnrelatedHostPublicationsDoNotInvalidateVisiblePanel() {
        let host = makePluginHostForTests(plugins: [])
        let presentation = MenuBarPanelPresentationModel(host: host, isVisible: true)
        var publications = 0
        let subscription = presentation.objectWillChange.sink { publications += 1 }
        host.objectWillChange.send()
        XCTAssertEqual(publications, 0)
        host.menuBarPanelContentDidChange.send()
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(subscription) {}
    }
}
