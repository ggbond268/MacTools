import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSnippetFocusResolverTests: XCTestCase {
    func testApplicationFocusIsPreferredWithoutQueryingSystemOrEnablingAccessibility() {
        let access = FocusAccess()
        access.applicationElement = .init(owner: 42, id: "application")
        access.systemElement = .init(owner: 42, id: "system")
        XCTAssertEqual(resolve(access, requestAccessibility: true)?.id, "application")
        XCTAssertEqual(access.systemQueries, 0)
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testUnavailableApplicationFocusFallsBackToSystemFocusFromSameApp() {
        let access = FocusAccess()
        access.systemElement = .init(owner: 42, id: "system")
        XCTAssertEqual(resolve(access, requestAccessibility: true)?.id, "system")
        XCTAssertEqual(access.systemQueries, 1)
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testSystemFocusFromAnotherAppIsRejected() {
        let access = FocusAccess()
        access.systemElement = .init(owner: 7, id: "other app")
        XCTAssertNil(resolve(access))
    }

    func testApplicationFocusFromAnotherProcessIsRejected() {
        let access = FocusAccess()
        access.applicationElement = .init(owner: 7, id: "other process")
        XCTAssertNil(resolve(access))
    }

    func testUnknownElementOwnershipIsRejected() {
        let access = FocusAccess()
        access.applicationElement = .init(owner: nil, id: "unknown application owner")
        access.systemElement = .init(owner: nil, id: "unknown system owner")
        XCTAssertNil(resolve(access))
    }

    func testMissingPermissionNeverReadsFocusOrRequestsAccessibility() {
        let access = FocusAccess()
        access.hasAccessibilityPermission = false
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertEqual(access.applicationQueries, 0)
        XCTAssertEqual(access.systemQueries, 0)
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testChangedForegroundAppNeverReadsFocusOrRequestsAccessibility() {
        let access = FocusAccess()
        access.frontmostProcessIdentifier = 7
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertEqual(access.applicationQueries, 0)
        XCTAssertEqual(access.systemQueries, 0)
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testFocusChangeDuringApplicationQueryStopsFallback() {
        let access = FocusAccess()
        access.applicationElement = .init(owner: 42, id: "stale")
        access.afterApplicationQuery = { access.frontmostProcessIdentifier = 7 }
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertEqual(access.systemQueries, 0)
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testFocusChangeDuringSystemQueryRejectsStaleElement() {
        let access = FocusAccess()
        access.systemElement = .init(owner: 42, id: "stale")
        access.afterSystemQuery = { access.frontmostProcessIdentifier = 7 }
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testRevokedPermissionDuringQueryRejectsElement() {
        let access = FocusAccess()
        access.systemElement = .init(owner: 42, id: "stale")
        access.afterSystemQuery = { access.hasAccessibilityPermission = false }
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testMissingFocusRequestsAccessibilityOnlyWhenExplicitlyAllowed() {
        let access = FocusAccess()
        XCTAssertNil(resolve(access))
        XCTAssertEqual(access.accessibilityRequests, 0)
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertEqual(access.accessibilityRequests, 1)
    }

    func testLazyAccessibilityTreeCanResolveOnNextAttemptWithoutRequestingAgain() {
        let access = FocusAccess()
        XCTAssertNil(resolve(access, requestAccessibility: true))
        access.applicationElement = .init(owner: 42, id: "editor now available")
        XCTAssertEqual(resolve(access)?.id, "editor now available")
        XCTAssertEqual(access.accessibilityRequests, 1)
    }

    func testUnavailableAccessibilityTreeRemainsFailClosed() {
        let access = FocusAccess()
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertNil(resolve(access))
        XCTAssertEqual(access.accessibilityRequests, 1)
    }

    func testInvalidProcessIsRejected() {
        let access = FocusAccess()
        access.frontmostProcessIdentifier = 0
        XCTAssertNil(ClipboardSnippetFocusResolver(access: access).resolve(
            processIdentifier: 0,
            requestManualAccessibilityIfNeeded: true
        ))
        XCTAssertEqual(access.applicationQueries, 0)
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testRemoteEditorIsAcceptedOnlyWithVerifiedForegroundWindow() {
        let access = remoteEditorAccess()
        XCTAssertEqual(resolve(access)?.id, "web editor")
        XCTAssertEqual(access.systemQueries, 0)
    }

    func testSystemFocusedRemoteEditorAlsoRequiresVerifiedWindow() {
        let access = remoteEditorAccess()
        access.systemElement = access.applicationElement
        access.applicationElement = nil
        XCTAssertEqual(resolve(access)?.id, "web editor")
    }

    func testRemoteEditorInAnotherWindowOfSameAppIsRejected() {
        let access = remoteEditorAccess()
        access.applicationWindow = .init(owner: 42, id: "another window")
        XCTAssertNil(resolve(access))
    }

    func testRemoteEditorWithForeignHostWindowIsRejected() {
        let access = remoteEditorAccess()
        access.elementWindow = .init(owner: 7, id: "foreign window")
        access.applicationWindow = access.elementWindow
        XCTAssertNil(resolve(access))
    }

    func testRemoteEditorWithoutWindowIsRejected() {
        let access = remoteEditorAccess()
        access.elementWindow = nil
        XCTAssertNil(resolve(access))
    }

    func testRemoteEditorWithoutFocusedHostWindowIsRejected() {
        let access = remoteEditorAccess()
        access.applicationWindow = nil
        XCTAssertNil(resolve(access))
    }

    func testRemoteEditorCannotSurviveAppSwitchDuringWindowLookup() {
        let access = remoteEditorAccess()
        access.afterWindowQuery = { access.frontmostProcessIdentifier = 7 }
        XCTAssertNil(resolve(access, requestAccessibility: true))
        XCTAssertEqual(access.accessibilityRequests, 0)
    }

    func testRemoteEditorCannotSurvivePermissionRevocationDuringWindowLookup() {
        let access = remoteEditorAccess()
        access.afterWindowQuery = { access.hasAccessibilityPermission = false }
        XCTAssertNil(resolve(access))
    }

    func testFocusDiagnosticsDistinguishMissingEditorFromUnverifiedOwnership() {
        let access = FocusAccess()
        var failure: ClipboardSnippetFocusFailure?
        XCTAssertNil(ClipboardSnippetFocusResolver(access: access).resolve(
            processIdentifier: 42, onFailure: { failure = $0 }
        ))
        XCTAssertEqual(failure, .unavailable)
        access.applicationElement = .init(owner: 7, id: "unverified editor")
        XCTAssertNil(ClipboardSnippetFocusResolver(access: access).resolve(
            processIdentifier: 42, onFailure: { failure = $0 }
        ))
        XCTAssertEqual(failure, .ownershipUnverified)
    }

    private func remoteEditorAccess() -> FocusAccess {
        let access = FocusAccess()
        access.applicationElement = .init(owner: 84, id: "web editor")
        access.elementWindow = .init(owner: 42, id: "host window")
        access.applicationWindow = access.elementWindow
        return access
    }

    private func resolve(_ access: FocusAccess, requestAccessibility: Bool = false) -> FocusAccess.Element? {
        ClipboardSnippetFocusResolver(access: access).resolve(
            processIdentifier: 42,
            requestManualAccessibilityIfNeeded: requestAccessibility
        )
    }
}

@MainActor
private final class FocusAccess: ClipboardSnippetFocusAccess {
    struct Element {
        let owner: pid_t?
        let id: String
    }

    var hasAccessibilityPermission = true
    var frontmostProcessIdentifier: pid_t? = 42
    var applicationElement: Element?
    var systemElement: Element?
    var elementWindow: Element?
    var applicationWindow: Element?
    var applicationQueries = 0
    var systemQueries = 0
    var accessibilityRequests = 0
    var afterApplicationQuery: (() -> Void)?
    var afterSystemQuery: (() -> Void)?
    var afterWindowQuery: (() -> Void)?

    func applicationFocusedElement(processIdentifier: pid_t) -> Element? {
        applicationQueries += 1
        afterApplicationQuery?()
        return applicationElement
    }

    func systemFocusedElement() -> Element? {
        systemQueries += 1
        afterSystemQuery?()
        return systemElement
    }

    func processIdentifier(of element: Element) -> pid_t? { element.owner }

    func window(of element: Element) -> Element? { elementWindow }

    func focusedWindow(processIdentifier: pid_t) -> Element? {
        afterWindowQuery?()
        return applicationWindow
    }

    func isSameElement(_ first: Element, _ second: Element) -> Bool {
        first.owner == second.owner && first.id == second.id
    }

    func requestManualAccessibility(processIdentifier: pid_t) {
        XCTAssertEqual(processIdentifier, 42)
        accessibilityRequests += 1
    }
}
