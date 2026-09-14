import ApplicationServices
import Foundation

/// Control discovery must not depend on the size or rendering state of a conversation.
struct SiriAXTraversal {
    enum Scope {
        case windowControls
        case messageEvidence
    }
    enum NewConversationPreparation {
        case pressButton(AXUIElement)
        case reuseEmptyConversation(input: AXUIElement, chat: AXUIElement, selectedRows: [AXUIElement])
    }

    let access: SiriAXAccess

    func identifier(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws -> String? {
        let value = try access.attribute(element, kAXIdentifierAttribute, deadline: deadline, allowsMissing: true)
        guard let value else { return nil }
        guard let identifier = value as? String else { throw SiriFailure.missingControls }
        return identifier
    }

    func elements(_ root: AXUIElement, scope: Scope,
                  deadline: ContinuousClock.Instant) throws -> [AXUIElement] {
        var stack = [(root, 0)]
        var result: [AXUIElement] = []
        while let (element, depth) = stack.popLast() {
            try Task.checkCancellation()
            guard result.count < 600, depth < 24 else { throw SiriFailure.missingControls }
            result.append(element)
            let id = try identifier(element, deadline: deadline)
            let role = try access.string(element, kAXRoleAttribute, deadline: deadline)
            if id == "chatListView" || role == kAXMenuBarRole { continue }
            if scope == .windowControls && id == "chatSessionView" { continue }
            if scope == .messageEvidence && id == "modelResponse" { continue }
            let children = try access.children(element, role: role, deadline: deadline)
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return result
    }

    func unique(_ id: String, role: String? = nil, in root: AXUIElement,
                deadline: ContinuousClock.Instant) throws -> AXUIElement {
        let matches = try elements(root, scope: .windowControls, deadline: deadline).filter {
            try identifier($0, deadline: deadline) == id
                && (role == nil || access.string($0, kAXRoleAttribute, deadline: deadline) == role)
        }
        guard matches.count == 1 else { throw SiriFailure.missingControls }
        return matches[0]
    }

    func newConversationPreparation(in window: AXUIElement,
                                    deadline: ContinuousClock.Instant) throws -> NewConversationPreparation {
        let controls = try elements(window, scope: .windowControls, deadline: deadline).map {
            (element: $0, id: try identifier($0, deadline: deadline),
             role: try access.string($0, kAXRoleAttribute, deadline: deadline))
        }
        let buttons = controls.filter { $0.id == "newChatButton" }
        guard buttons.count == 1, buttons[0].role == kAXButtonRole,
              let enabled = try access.attribute(buttons[0].element, kAXEnabledAttribute, deadline: deadline) as? Bool else { throw SiriFailure.missingControls }
        let inputs = controls.filter { $0.id == "promptViewTextField" }
        if inputs.count == 1, inputs[0].role == kAXTextFieldRole {
            guard try access.string(inputs[0].element, kAXValueAttribute, deadline: deadline).isEmpty else {
                throw SiriFailure.existingDraft
            }
            if !enabled {
                let chats = controls.filter { $0.id == "innerChatSessionView" }
                guard chats.count == 1 else { throw SiriFailure.missingControls }
                let transcript = try unique("chatSessionView", in: chats[0].element, deadline: deadline)
                let role = try access.string(transcript, kAXRoleAttribute, deadline: deadline)
                guard role == kAXUnknownRole || role == kAXGroupRole,
                      let children = try access.attribute(transcript, kAXChildrenAttribute,
                                                          deadline: deadline) as? [AXUIElement] else {
                    throw SiriFailure.missingControls
                }
                guard children.isEmpty, try userMessages(in: chats[0].element, deadline: deadline).isEmpty else {
                    throw SiriFailure.destinationChanged
                }
                let selected = try selection(in: window, deadline: deadline)
                guard selected.count <= 1 else { throw SiriFailure.ambiguousWindow }
                try access.requireWritableInput(inputs[0].element, deadline: deadline)
                return .reuseEmptyConversation(input: inputs[0].element, chat: chats[0].element, selectedRows: selected)
            }
        } else {
            // Siri's empty-selection screen has no composer until New Chat is pressed. Require
            // positive selection evidence, and never infer an empty draft from an absent control.
            guard enabled, inputs.isEmpty,
                  !controls.contains(where: { $0.id == "innerChatSessionView" }),
                  !controls.contains(where: { $0.role == kAXTextFieldRole || $0.role == kAXTextAreaRole }) else {
                throw SiriFailure.missingControls
            }
            guard try selection(in: window, deadline: deadline).isEmpty else { throw SiriFailure.missingControls }
        }
        return .pressButton(buttons[0].element)
    }

    private func selection(in window: AXUIElement, deadline: ContinuousClock.Instant) throws -> [AXUIElement] {
        let outline = try unique("chatListView", role: kAXOutlineRole, in: window, deadline: deadline)
        guard let selected = try access.attribute(outline, kAXSelectedRowsAttribute,
                                                 deadline: deadline) as? [AXUIElement] else {
            throw SiriFailure.missingControls
        }
        return selected
    }

    func userMessages(in chat: AXUIElement, deadline: ContinuousClock.Instant) throws -> [String] {
        try elements(chat, scope: .messageEvidence, deadline: deadline).filter {
            try identifier($0, deadline: deadline) == "userPrompt"
        }.map { prompt in
            try elements(prompt, scope: .messageEvidence, deadline: deadline).filter {
                try access.string($0, kAXRoleAttribute, deadline: deadline) == kAXStaticTextRole
            }.map { try access.string($0, kAXValueAttribute, deadline: deadline) }.joined()
        }
    }
}
