import XCTest
@testable import WindowLayoutPlugin

final class WindowLayoutHistoryTests: XCTestCase {
    func testKeepsOriginalSnapshotAcrossMultipleLayouts() {
        let history = WindowLayoutHistory()
        let key = WindowLayoutWindowKey(pid: 1, windowID: "w1")
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        history.snapshotIfNeeded(key: key, frame: original)
        history.snapshotIfNeeded(key: key, frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(history.frame(for: key), original)
    }

    func testClearRemovesSnapshot() {
        let history = WindowLayoutHistory()
        let key = WindowLayoutWindowKey(pid: 1, windowID: "w1")
        history.snapshotIfNeeded(key: key, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        history.clear(key)
        XCTAssertNil(history.frame(for: key))
    }
}
