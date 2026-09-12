import CoreServices
import XCTest
@testable import StorageExplorerPlugin

final class StorageExplorerFileObserverTests: XCTestCase {
    func testHistoryCompletionMarkerDoesNotInvalidateSnapshot() {
        let disposition = StorageExplorerFileObserver.disposition(
            paths: ["/tmp/storage"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)]
        )

        XCTAssertEqual(disposition, .ignore)
    }

    func testItemMutationReportsOnlyChangedPaths() {
        let disposition = StorageExplorerFileObserver.disposition(
            paths: ["/tmp/storage", "/tmp/storage/file"],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
            ]
        )

        XCTAssertEqual(disposition, .changedPaths(["/tmp/storage/file"]))
    }

    func testDroppedOrWrappedEventsInvalidateEntireSnapshot() {
        for flag in [
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagEventIdsWrapped,
        ] {
            let disposition = StorageExplorerFileObserver.disposition(
                paths: ["/tmp/storage"],
                flags: [FSEventStreamEventFlags(flag)]
            )
            XCTAssertEqual(disposition, .invalidateAll)
        }
    }
}
