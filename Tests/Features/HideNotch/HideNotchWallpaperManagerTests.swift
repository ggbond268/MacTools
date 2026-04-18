import XCTest
@testable import MacTools

@MainActor
final class HideNotchDesktopMaskManagerTests: XCTestCase {
    func testSynchronizeCreatesOneWindowPerSupportedDisplay() throws {
        let primary = makeHideNotchDisplayRecord(
            id: 1,
            displayIdentifier: "BUILTIN-1"
        ).context
        let secondary = makeHideNotchDisplayRecord(
            id: 2,
            displayIdentifier: "BUILTIN-2",
            frame: CGRect(x: 1512, y: 0, width: 1512, height: 982)
        ).context

        let builder = RecordingHideNotchDesktopMaskWindowBuilder()
        let manager = HideNotchDesktopMaskManager(windowBuilder: builder)

        try manager.synchronizeMasks(for: [primary, secondary])

        XCTAssertEqual(builder.createdFrames.count, 2)
        XCTAssertEqual(manager.managedDisplayIdentifiers, Set(["BUILTIN-1", "BUILTIN-2"]))
        XCTAssertEqual(builder.windowsByOriginX[0]?.showCallCount, 1)
        XCTAssertEqual(builder.windowsByOriginX[1512]?.showCallCount, 1)
    }

    func testSynchronizeUpdatesExistingWindowsAndClosesRemovedDisplays() throws {
        let firstPass = makeHideNotchDisplayRecord(
            id: 1,
            displayIdentifier: "BUILTIN-1",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchHeightPoints: 36
        ).context
        let secondPass = makeHideNotchDisplayRecord(
            id: 1,
            displayIdentifier: "BUILTIN-1",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchHeightPoints: 48
        ).context
        let removedDisplay = makeHideNotchDisplayRecord(
            id: 2,
            displayIdentifier: "BUILTIN-2",
            frame: CGRect(x: 1512, y: 0, width: 1512, height: 982)
        ).context

        let builder = RecordingHideNotchDesktopMaskWindowBuilder()
        let manager = HideNotchDesktopMaskManager(windowBuilder: builder)

        try manager.synchronizeMasks(for: [firstPass, removedDisplay])
        try manager.synchronizeMasks(for: [secondPass])

        let updatedWindow = builder.windowsByOriginX[0]
        XCTAssertEqual(updatedWindow?.frames.last?.height, 48)
        XCTAssertEqual(updatedWindow?.showCallCount, 2)
        XCTAssertEqual(builder.windowsByOriginX[1512]?.closeCallCount, 1)
        XCTAssertEqual(manager.managedDisplayIdentifiers, Set(["BUILTIN-1"]))
    }

    func testSynchronizeIgnoresUnsupportedDisplays() throws {
        let unsupported = makeHideNotchDisplayRecord(
            id: 3,
            displayIdentifier: "EXTERNAL-1",
            name: "Studio Display",
            isBuiltin: false,
            isSupported: false
        ).context

        let builder = RecordingHideNotchDesktopMaskWindowBuilder()
        let manager = HideNotchDesktopMaskManager(windowBuilder: builder)

        try manager.synchronizeMasks(for: [unsupported])

        XCTAssertTrue(builder.createdFrames.isEmpty)
        XCTAssertTrue(manager.managedDisplayIdentifiers.isEmpty)
    }

    func testSynchronizeSurfacesWindowCreationFailures() {
        let supported = makeHideNotchDisplayRecord(
            id: 4,
            displayIdentifier: "BUILTIN-ERR"
        ).context

        let builder = RecordingHideNotchDesktopMaskWindowBuilder()
        builder.makeWindowError = StubHideNotchDesktopMaskWindowBuilderError.forcedFailure
        let manager = HideNotchDesktopMaskManager(windowBuilder: builder)

        XCTAssertThrowsError(try manager.synchronizeMasks(for: [supported])) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "无法为 Built-in Retina Display 创建刘海遮挡层：forced failure"
            )
        }
    }
}
