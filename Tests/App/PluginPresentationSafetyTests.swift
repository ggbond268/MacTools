import AppKit
import MacToolsPluginKit
import XCTest

final class PluginCallbackContextTests: XCTestCase {
    private final class Owner {
        private let onDeinit: () -> Void

        init(onDeinit: @escaping () -> Void = {}) {
            self.onDeinit = onDeinit
        }

        deinit {
            onDeinit()
        }
    }

    func testInvalidationPreventsNewCallbackDelivery() {
        let owner = Owner()
        let context = PluginCallbackContext(owner: owner)
        var deliveryCount = 0

        context.withOwner { _ in deliveryCount += 1 }
        context.invalidate()
        context.withOwner { _ in deliveryCount += 1 }

        XCTAssertEqual(deliveryCount, 1)
    }

    func testAdmittedCallbackRetainsOwnerUntilDeliveryCompletes() throws {
        var didDeinitialize = false
        var owner: Owner? = Owner { didDeinitialize = true }
        let context = PluginCallbackContext(owner: try XCTUnwrap(owner))

        context.withOwner { _ in
            owner = nil
            XCTAssertFalse(didDeinitialize)
        }

        XCTAssertTrue(didDeinitialize)
    }
}
