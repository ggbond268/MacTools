import XCTest
@testable import WindowSwitcherPlugin

final class WindowSwitcherProcessMappingTests: XCTestCase {
    func testNestedHelperBundleMapsToTheLongestHostPath() {
        let chrome = candidate(100, bundle: "com.google.Chrome", path: "/Applications/Google Chrome.app", regular: true)
        let canary = candidate(101, bundle: "com.google.Chrome.canary", path: "/Applications/Google Chrome Canary.app", regular: true)
        let helper = candidate(
            200,
            bundle: "com.google.Chrome.helper",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app",
            regular: false
        )
        let snapshot = WindowSwitcherProcessMapping.snapshot(candidates: [chrome, canary, helper], ownPID: 1)
        XCTAssertEqual(snapshot.host(for: 200), 100)
        XCTAssertEqual(snapshot.host(for: 100), 100)
        XCTAssertEqual(snapshot.hostByOwner, [200: 100])
    }

    func testAccessoryHelperBundleNameMapsWhenPathIsUnavailable() {
        let chrome = candidate(100, bundle: "com.google.Chrome", path: nil, regular: true)
        let helper = candidate(200, bundle: "com.google.Chrome.helper", path: nil, regular: false)
        let snapshot = WindowSwitcherProcessMapping.snapshot(candidates: [chrome, helper], ownPID: 1)
        XCTAssertEqual(snapshot.host(for: 200), 100)
    }

    func testRegularSiblingAppsAreNotTreatedAsHelpers() {
        let chrome = candidate(100, bundle: "com.google.Chrome", path: "/Applications/Google Chrome.app", regular: true)
        let canary = candidate(101, bundle: "com.google.Chrome.canary", path: "/Applications/Google Chrome Canary.app", regular: true)
        let snapshot = WindowSwitcherProcessMapping.snapshot(candidates: [chrome, canary], ownPID: 1)
        XCTAssertEqual(snapshot.host(for: 101), 101)
        XCTAssertTrue(snapshot.hostByOwner.isEmpty)
    }

    func testHelpersOwningWindowsAreTheOnlyOnesScanned() {
        let snapshot = WindowSwitcherProcessMapping.Snapshot(hostByOwner: [200: 100, 201: 100, 300: 101])
        let records = [
            WindowSwitcherWindowRecord(windowNumber: 1, processIdentifier: 200, title: "Tab", isOnScreen: true,
                                       bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            WindowSwitcherWindowRecord(windowNumber: 2, processIdentifier: 300, title: "Other", isOnScreen: true,
                                       bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            WindowSwitcherWindowRecord(windowNumber: 3, processIdentifier: 200, title: "Second tab", isOnScreen: true,
                                       bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            WindowSwitcherWindowRecord(windowNumber: 4, processIdentifier: 999, title: "Unmapped", isOnScreen: true,
                                       bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]
        XCTAssertEqual(snapshot.helpersByHost(owningWindowsIn: records), [100: [200], 101: [300]])
        XCTAssertTrue(snapshot.helpersByHost(owningWindowsIn: []).isEmpty)
    }

    private func candidate(_ pid: pid_t, bundle: String?, path: String?, regular: Bool) -> WindowSwitcherProcessMapping.Candidate {
        WindowSwitcherProcessMapping.Candidate(
            processIdentifier: pid,
            bundleIdentifier: bundle,
            bundlePath: path,
            isRegular: regular
        )
    }
}
