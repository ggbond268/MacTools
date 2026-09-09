import ApplicationServices
import Foundation
import XCTest
@testable import SiriPlugin

@MainActor
final class SiriAXTraversalTests: XCTestCase {
    func testWindowControlsIgnoreLargeAndDeepTranscripts() throws {
        for depth in [1, 30] {
            let messaging = TraversalMessaging(nodes: conversation(responseNodes: 650, responseDepth: depth))
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
            let deadline = ContinuousClock.now + .seconds(5)
            for id in ["promptViewTextField", "newChatButton", "innerChatSessionView"] {
                _ = try traversal.unique(id, in: element(100), deadline: deadline)
            }
            _ = try traversal.newConversationPreparation(in: element(100), deadline: deadline)
            XCTAssertFalse(messaging.reads.contains { $0.pid == 107 && $0.attribute == kAXChildrenAttribute })
            XCTAssertFalse(messaging.reads.contains { $0.pid == 104 || $0.pid >= 200 })
        }
    }

    func testExactUserMessageEvidenceIgnoresLargeAndDeepModelResponses() throws {
        for depth in [1, 30] {
            let messaging = TraversalMessaging(nodes: conversation(responseNodes: 650, responseDepth: depth))
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
            let messages = try traversal.userMessages(in: element(103), deadline: .now + .seconds(5))
            XCTAssertEqual(messages, ["  exact\n消息  "])
            XCTAssertFalse(messaging.reads.contains { $0.pid == 104 && $0.attribute == kAXChildrenAttribute })
            XCTAssertFalse(messaging.reads.contains { $0.pid >= 200 })
        }
    }

    func testDuplicateControlsOutsideTranscriptAreStillRejected() throws {
        var nodes = conversation(responseNodes: 1)
        nodes[900] = TraversalNode(role: kAXTextFieldRole, id: "promptViewTextField")
        nodes[100]?.children?.append(900)
        let messaging = TraversalMessaging(nodes: nodes)
        let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
        XCTAssertThrowsError(try traversal.unique("promptViewTextField", in: element(100), deadline: .now + .seconds(5))) {
            XCTAssertEqual($0 as? SiriFailure, .missingControls)
        }
    }

    func testMissingChatOrUnreadableChatContentsCannotProduceEvidence() {
        var nodes = conversation(responseNodes: 1)
        nodes[100]?.children = [101, 102]
        let missing = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: nodes)))
        XCTAssertThrowsError(try missing.unique("innerChatSessionView", in: element(100), deadline: .now + .seconds(5)))

        for error in [AXError.cannotComplete, .invalidUIElement, .attributeUnsupported, .noValue] {
            let messaging = TraversalMessaging(nodes: conversation(responseNodes: 1),
                                              failure: (103, kAXChildrenAttribute, error))
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
            XCTAssertThrowsError(try traversal.userMessages(in: element(103), deadline: .now + .seconds(5))) {
                XCTAssertEqual($0 as? SiriFailure, .missingControls)
            }
        }
    }

    func testUnreadablePromptValueCannotCountAsAnEmptyOrMatchingMessage() {
        let messaging = TraversalMessaging(nodes: conversation(responseNodes: 650),
                                          failure: (106, kAXValueAttribute, .cannotComplete))
        let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
        XCTAssertThrowsError(try traversal.userMessages(in: element(103), deadline: .now + .seconds(5)))
    }

    func testRelevantControlTraversalStillEnforcesNodeAndDepthLimits() {
        var manyNodes = conversation(responseNodes: 1)
        manyNodes[100]?.children = (200..<850).map { pid_t($0) }
        for pid in 200..<850 { manyNodes[pid_t(pid)] = TraversalNode(role: kAXButtonRole) }
        let many = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: manyNodes)))
        XCTAssertThrowsError(try many.unique("newChatButton", in: element(100), deadline: .now + .seconds(5)))

        var deepNodes = conversation(responseNodes: 1)
        deepNodes[100]?.children = [200]
        for pid in 200..<230 {
            deepNodes[pid_t(pid)] = TraversalNode(role: kAXGroupRole, children: [pid_t(pid + 1)])
        }
        deepNodes[230] = TraversalNode(role: kAXButtonRole, id: "newChatButton")
        let deep = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: deepNodes)))
        XCTAssertThrowsError(try deep.unique("newChatButton", in: element(100), deadline: .now + .seconds(5)))
    }

    func testEmptySelectionAllowsOnlyUniqueEnabledNewChatWithoutMutating() throws {
        let messaging = TraversalMessaging(nodes: emptySelection())
        let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
        let preparation = try traversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5))
        guard case let .pressButton(button) = preparation else { return XCTFail("Empty selection requires New Chat") }
        XCTAssertTrue(CFEqual(button, element(102)))
        XCTAssertTrue(messaging.reads.contains { $0.pid == 107 && $0.attribute == kAXSelectedRowsAttribute })

        for enabled in [false, nil] as [Bool?] {
            var nodes = emptySelection()
            nodes[102]?.enabled = enabled
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: nodes)))
            XCTAssertThrowsError(try traversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        }
        var duplicate = emptySelection()
        duplicate[108] = .init(role: kAXButtonRole, id: "newChatButton", enabled: true)
        duplicate[100]?.children?.append(108)
        let duplicateTraversal = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: duplicate)))
        XCTAssertThrowsError(try duplicateTraversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
    }

    func testNonemptyMissingMalformedOrUnreadableSelectionCannotAuthorizeNewChat() {
        for selection in [[108], nil] as [[pid_t]?] {
            var nodes = emptySelection()
            nodes[107]?.selectedRows = selection
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: nodes)))
            XCTAssertThrowsError(try traversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        }
        var malformed = emptySelection()
        malformed[107]?.malformedSelection = true
        let malformedTraversal = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: malformed)))
        XCTAssertThrowsError(try malformedTraversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        for error in [AXError.cannotComplete, .invalidUIElement, .attributeUnsupported, .noValue] {
            let messaging = TraversalMessaging(nodes: emptySelection(), failure: (107, kAXSelectedRowsAttribute, error))
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
            XCTAssertThrowsError(try traversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        }
    }

    func testExistingChatWithoutComposerOrUnknownTextInputIsNotEmptySelection() {
        for node in [TraversalNode(role: kAXGroupRole, id: "innerChatSessionView", children: []),
                     TraversalNode(role: kAXTextFieldRole, value: ""),
                     TraversalNode(role: kAXTextAreaRole, value: "", children: [])] {
            var nodes = emptySelection()
            nodes[108] = node
            nodes[100]?.children?.append(108)
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: nodes)))
            XCTAssertThrowsError(try traversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        }
    }

    func testUnreadableTreeOrExistingDraftCannotAuthorizeNewChat() {
        let unreadable = TraversalMessaging(nodes: emptySelection(), failure: (100, kAXChildrenAttribute, .cannotComplete))
        let unreadableTraversal = SiriAXTraversal(access: SiriAXAccess(messaging: unreadable))
        XCTAssertThrowsError(try unreadableTraversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))

        var draft = conversation(responseNodes: 1)
        draft[101]?.value = "user draft"
        let draftTraversal = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: draft)))
        XCTAssertThrowsError(try draftTraversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5))) {
            XCTAssertEqual($0 as? SiriFailure, .existingDraft)
        }
        let failedRead = TraversalMessaging(nodes: conversation(responseNodes: 1), failure: (101, kAXValueAttribute, .cannotComplete))
        let failedReadTraversal = SiriAXTraversal(access: SiriAXAccess(messaging: failedRead))
        XCTAssertThrowsError(try failedReadTraversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
    }

    func testDisabledNewChatReusesOnlyVerifiedEmptyConversationAndPinsItsSelection() throws {
        var nodes = conversation(responseNodes: 1)
        nodes[102]?.enabled = false
        nodes[107]?.children = []
        let messaging = TraversalMessaging(nodes: nodes)
        let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: messaging))
        let preparation = try traversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5))
        guard case let .reuseEmptyConversation(input, chat, selection) = preparation else {
            return XCTFail("An already empty chat must not press disabled New Chat")
        }
        XCTAssertTrue(CFEqual(input, element(101)))
        XCTAssertTrue(CFEqual(chat, element(103)))
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(selection.first), element(112)))
        XCTAssertTrue(messaging.reads.contains { $0.pid == 107 && $0.attribute == kAXChildrenAttribute })
    }

    func testDisabledNewChatCannotReuseMessagesMissingTranscriptOrUnreadableSelection() {
        var withMessages = conversation(responseNodes: 1)
        withMessages[102]?.enabled = false
        let existing = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: withMessages)))
        XCTAssertThrowsError(try existing.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        var withoutTranscript = withMessages
        withoutTranscript[103]?.children = [108, 109, 110]
        let missing = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: withoutTranscript)))
        XCTAssertThrowsError(try missing.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        var empty = withMessages
        empty[107]?.children = []
        var wrongRole = empty
        wrongRole[107] = .init(role: kAXStaticTextRole, id: "chatSessionView", value: "")
        let leaf = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: wrongRole)))
        XCTAssertThrowsError(try leaf.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        for failure in [(pid_t(107), kAXChildrenAttribute, AXError.cannotComplete),
                        (pid_t(107), kAXChildrenAttribute, AXError.noValue),
                        (pid_t(111), kAXSelectedRowsAttribute, AXError.cannotComplete)] {
            let traversal = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: empty, failure: failure)))
            XCTAssertThrowsError(try traversal.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        }
        let notWritable = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: empty, writable: false)))
        XCTAssertThrowsError(try notWritable.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
        var draft = empty
        draft[101]?.value = "user draft"
        let withDraft = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: draft)))
        XCTAssertThrowsError(try withDraft.newConversationPreparation(in: element(100), deadline: .now + .seconds(5))) {
            XCTAssertEqual($0 as? SiriFailure, .existingDraft)
        }
        empty[111]?.selectedRows = [112, 113]
        let ambiguous = SiriAXTraversal(access: SiriAXAccess(messaging: TraversalMessaging(nodes: empty)))
        XCTAssertThrowsError(try ambiguous.newConversationPreparation(in: element(100), deadline: .now + .seconds(5)))
    }

    private func element(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    private func emptySelection() -> [pid_t: TraversalNode] {
        [100: .init(role: kAXWindowRole, children: [102, 107]),
         102: .init(role: kAXButtonRole, id: "newChatButton", enabled: true),
         107: .init(role: kAXOutlineRole, id: "chatListView", selectedRows: [])]
    }

    private func conversation(responseNodes: Int, responseDepth: Int = 1) -> [pid_t: TraversalNode] {
        var nodes: [pid_t: TraversalNode] = [
            100: .init(role: kAXWindowRole, children: [102, 103, 111]),
            101: .init(role: kAXTextFieldRole, id: "promptViewTextField", value: ""),
            102: .init(role: kAXButtonRole, id: "newChatButton", enabled: true),
            103: .init(role: kAXGroupRole, id: "innerChatSessionView", children: [107, 108, 109, 110]),
            104: .init(role: kAXGroupRole, id: "modelResponse", children: [200]),
            105: .init(role: kAXGroupRole, id: "userPrompt", children: [106]),
            106: .init(role: kAXStaticTextRole, value: "  exact\n消息  "),
            107: .init(role: kAXUnknownRole, id: "chatSessionView", children: [105, 104]),
            108: .init(role: kAXGroupRole, id: "promptView", children: [101]),
            109: .init(role: kAXButtonRole, id: "addAttachmentButton"),
            110: .init(role: kAXButtonRole, id: "voiceModeButton"),
            111: .init(role: kAXOutlineRole, id: "chatListView", selectedRows: [112]),
        ]
        var parent: pid_t = 104
        for offset in 0..<responseDepth {
            let pid = pid_t(200 + offset)
            nodes[parent]?.children = [pid]
            nodes[pid] = .init(role: kAXGroupRole, children: [])
            parent = pid
        }
        let leaves = (0..<responseNodes).map { pid_t(1000 + $0) }
        nodes[parent]?.children = leaves
        for pid in leaves { nodes[pid] = .init(role: kAXStaticTextRole, value: "model response") }
        return nodes
    }
}

private struct TraversalNode {
    let role: String
    var id: String? = nil
    var value: String? = nil
    var children: [pid_t]? = nil
    var enabled: Bool? = nil
    var selectedRows: [pid_t]? = nil
    var malformedSelection = false
}

/// AX references are identity tokens only; every remote operation is replaced with this fake.
private final class TraversalMessaging: SiriAXMessaging, @unchecked Sendable {
    struct Read { let pid: pid_t; let attribute: String }
    private let nodes: [pid_t: TraversalNode]
    private let failure: (pid_t, String, AXError)?
    private let writable: Bool
    private let lock = NSLock()
    private var recordedReads: [Read] = []
    var reads: [Read] { lock.withLock { recordedReads } }

    init(nodes: [pid_t: TraversalNode], failure: (pid_t, String, AXError)? = nil, writable: Bool = true) {
        self.nodes = nodes
        self.failure = failure
        self.writable = writable
    }
    func setTimeout(_ element: AXUIElement, seconds: Float) -> AXError { .success }
    func copyAttribute(_ element: AXUIElement, name: String) -> (AXError, CFTypeRef?) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return (.invalidUIElement, nil) }
        lock.withLock { recordedReads.append(Read(pid: pid, attribute: name)) }
        if let failure, failure.0 == pid, failure.1 == name { return (failure.2, nil) }
        guard let node = nodes[pid] else { return (.invalidUIElement, nil) }
        switch name {
        case kAXRoleAttribute: return (.success, node.role as CFString)
        case kAXIdentifierAttribute:
            return node.id.map { (.success, $0 as CFString) } ?? (.attributeUnsupported, nil)
        case kAXValueAttribute:
            return node.value.map { (.success, $0 as CFString) } ?? (.attributeUnsupported, nil)
        case kAXChildrenAttribute:
            return node.children.map { (.success, $0.map(AXUIElementCreateApplication) as CFArray) }
                ?? (.attributeUnsupported, nil)
        case kAXEnabledAttribute:
            return node.enabled.map { (.success, $0 ? kCFBooleanTrue : kCFBooleanFalse) } ?? (.attributeUnsupported, nil)
        case kAXSelectedRowsAttribute:
            if node.malformedSelection { return (.success, "invalid" as CFString) }
            return node.selectedRows.map { (.success, $0.map(AXUIElementCreateApplication) as CFArray) }
                ?? (.attributeUnsupported, nil)
        default: return (.attributeUnsupported, nil)
        }
    }
    func isSettable(_ element: AXUIElement, name: String) -> (AXError, Bool) {
        return (.success, writable)
    }
    func actionNames(_ element: AXUIElement) -> (AXError, [String]?) {
        return (.success, ["AXConfirm"])
    }
    func setValue(_ element: AXUIElement, name: String, value: CFTypeRef) -> AXError {
        XCTFail("Traversal must not write")
        return .failure
    }
    func perform(_ element: AXUIElement, action: String) -> AXError {
        XCTFail("Traversal must not perform actions")
        return .failure
    }
}
