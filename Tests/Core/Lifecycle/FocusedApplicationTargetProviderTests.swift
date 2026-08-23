import XCTest
@testable import MacTools

@MainActor
final class FocusedApplicationTargetProviderTests: XCTestCase {
    func testRetainsLastExternalApplicationWhileMacToolsIsFrontmost() {
        let externalApplication = FakeFocusedApplication(processIdentifier: 200)
        let hostApplication = FakeFocusedApplication(processIdentifier: 100)
        var frontmostApplication: (any FocusedApplicationTargetApplication)? = externalApplication
        let provider = SystemFocusedApplicationTargetProvider(
            currentProcessIdentifier: 100,
            observesWorkspace: false,
            frontmostApplication: { frontmostApplication }
        )

        XCTAssertEqual(provider.targetProcessIdentifier(), 200)

        frontmostApplication = hostApplication
        XCTAssertEqual(provider.targetProcessIdentifier(), 200)

        externalApplication.isTerminated = true
        XCTAssertNil(provider.targetProcessIdentifier())
    }

    func testDoesNotRetargetReplacementProcessThatReusesTerminatedPID() {
        let originalApplication = FakeFocusedApplication(processIdentifier: 200)
        let hostApplication = FakeFocusedApplication(processIdentifier: 100)
        var frontmostApplication: (any FocusedApplicationTargetApplication)? = originalApplication
        let provider = SystemFocusedApplicationTargetProvider(
            currentProcessIdentifier: 100,
            observesWorkspace: false,
            frontmostApplication: { frontmostApplication }
        )
        XCTAssertEqual(provider.targetProcessIdentifier(), 200)

        frontmostApplication = hostApplication
        originalApplication.isTerminated = true
        let replacementApplication = FakeFocusedApplication(processIdentifier: 200)

        XCTAssertNil(provider.targetProcessIdentifier())
        withExtendedLifetime(replacementApplication) {}
    }

    func testActivationUpdatesExternalTargetButIgnoresHostActivation() {
        let hostApplication = FakeFocusedApplication(processIdentifier: 100)
        let externalApplication = FakeFocusedApplication(processIdentifier: 300)
        let provider = SystemFocusedApplicationTargetProvider(
            currentProcessIdentifier: 100,
            observesWorkspace: false,
            frontmostApplication: { hostApplication }
        )

        provider.recordActivatedApplication(hostApplication)
        XCTAssertNil(provider.targetProcessIdentifier())

        provider.recordActivatedApplication(externalApplication)
        XCTAssertEqual(provider.targetProcessIdentifier(), 300)
    }

    func testRecordedHostWindowIsTargetedUntilAnotherExternalApplicationActivates() {
        let hostApplication = FakeFocusedApplication(processIdentifier: 100)
        let externalApplication = FakeFocusedApplication(processIdentifier: 200)
        var frontmostApplication: (any FocusedApplicationTargetApplication)? = hostApplication
        let provider = SystemFocusedApplicationTargetProvider(
            currentProcessIdentifier: 100,
            observesWorkspace: false,
            frontmostApplication: { frontmostApplication }
        )

        provider.recordHostTarget(application: hostApplication, windowNumber: 42)
        XCTAssertEqual(provider.targetProcessIdentifier(), 100)
        XCTAssertEqual(provider.targetWindowNumber(), 42)

        frontmostApplication = externalApplication
        XCTAssertEqual(provider.targetProcessIdentifier(), 200)
        XCTAssertNil(provider.targetWindowNumber())

        frontmostApplication = hostApplication
        XCTAssertEqual(provider.targetProcessIdentifier(), 200)
        XCTAssertNil(provider.targetWindowNumber())
    }

    func testCapturePreservesExternalTargetWhileTransientHostSurfaceIsFrontmost() {
        let hostApplication = FakeFocusedApplication(processIdentifier: 100)
        let externalApplication = FakeFocusedApplication(processIdentifier: 200)
        var frontmostApplication: (any FocusedApplicationTargetApplication)? = externalApplication
        let provider = SystemFocusedApplicationTargetProvider(
            currentProcessIdentifier: 100,
            observesWorkspace: false,
            frontmostApplication: { frontmostApplication }
        )

        provider.captureCurrentTarget()
        frontmostApplication = hostApplication

        XCTAssertEqual(provider.targetProcessIdentifier(), 200)
        XCTAssertNil(provider.targetWindowNumber())
    }
}

@MainActor
private final class FakeFocusedApplication: FocusedApplicationTargetApplication {
    let processIdentifier: Int32
    var isTerminated = false

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }
}
