import AppKit
import ApplicationServices
import Foundation

/// AX references stay on this actor. Each call has a messaging timeout and bounded traversal.
actor SiriAccessibilityClient: SiriClient {
    private struct Destination {
        let pid: pid_t
        let launchDate: Date?
        let app: AXUIElement
        let window: AXUIElement
        let input: AXUIElement
        let chat: AXUIElement
        let selectedRows: [AXUIElement]
    }
    private var destination: Destination?
    private var deadline = ContinuousClock.now
    private var text: String?

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }
    private func elements(_ root: AXUIElement) throws -> [AXUIElement] {
        var stack = [(root, 0)]
        var result: [AXUIElement] = []
        while let (element, depth) = stack.popLast() {
            try checkDeadline()
            guard result.count < 600, depth < 24 else { throw SiriFailure.missingControls }
            result.append(element)
            let id = string(element, kAXIdentifierAttribute)
            if id == "chatListView" || string(element, kAXRoleAttribute) == "AXMenuBar" { continue }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return result
    }
    private func unique(_ id: String, role: String? = nil, in root: AXUIElement) throws -> AXUIElement {
        let matches = try elements(root).filter {
            string($0, kAXIdentifierAttribute) == id && (role == nil || string($0, kAXRoleAttribute) == role)
        }
        guard matches.count == 1 else { throw SiriFailure.missingControls }
        return matches[0]
    }
    private func checkDeadline() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw SiriFailure.timedOut }
    }
    private func pause(until limit: ContinuousClock.Instant) async throws {
        try checkDeadline()
        guard ContinuousClock.now < limit else { throw SiriFailure.timedOut }
        try await Task.sleep(for: .milliseconds(150))
    }
    private func selectedRows(_ window: AXUIElement) throws -> [AXUIElement] {
        let outlines = try elements(window).filter { string($0, kAXIdentifierAttribute) == "chatListView" }
        guard outlines.count == 1 else { throw SiriFailure.missingControls }
        guard let selected = attribute(outlines[0], kAXSelectedRowsAttribute) as? [AXUIElement] else {
            throw SiriFailure.missingControls
        }
        return selected
    }
    private func same(_ a: [AXUIElement], _ b: [AXUIElement]) -> Bool {
        a.count == b.count && zip(a,b).allSatisfy { CFEqual($0, $1) }
    }
    private func checkDestination(_ d: Destination, beforeSubmit: Bool) async throws {
        try checkDeadline()
        guard AXIsProcessTrusted() else { throw SiriFailure.permission }
        let pid = d.pid
        let launchDate = d.launchDate
        let alive = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated && app.bundleIdentifier == "com.apple.campo" && app.launchDate == launchDate
        }
        guard alive, let windows = attribute(d.app, kAXWindowsAttribute) as? [AXUIElement],
              windows.contains(where: { CFEqual($0, d.window) }),
              CFEqual(try unique("promptViewTextField", role: "AXTextField", in: d.window), d.input),
              CFEqual(try unique("innerChatSessionView", in: d.window), d.chat) else {
            throw SiriFailure.destinationChanged
        }
        if beforeSubmit {
            guard same(try selectedRows(d.window), d.selectedRows),
                  try userMessages(d.chat).isEmpty else { throw SiriFailure.destinationChanged }
        }
    }
    private func userMessages(_ chat: AXUIElement) throws -> [String] {
        try elements(chat).filter { string($0,kAXIdentifierAttribute) == "userPrompt" }.map { prompt in
            try elements(prompt).filter { string($0,kAXRoleAttribute) == "AXStaticText" }
                .map { string($0,kAXValueAttribute) }.joined()
        }
    }

    func prepareNewConversation() async throws {
        deadline = ContinuousClock.now.advanced(by: .seconds(45))
        guard AXIsProcessTrusted() else { throw SiriFailure.permission }
        let identity = try await Self.openSiri()
        try checkDeadline()
        let app = AXUIElementCreateApplication(identity.0)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: AXUIElement?
        let windowDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while window == nil {
            try checkDeadline()
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if windows.count == 1 { window = windows[0] }
            else if windows.count > 1 {
                let selected = windows.filter { (attribute($0,kAXMainAttribute) as? Bool) == true }
                guard selected.count == 1 else { throw SiriFailure.ambiguousWindow }
                window = selected[0]
            }
            if window == nil { try await pause(until: windowDeadline) }
        }
        guard let window else { throw SiriFailure.missingControls }
        let input = try unique("promptViewTextField", role: "AXTextField", in: window)
        guard string(input,kAXValueAttribute).isEmpty else { throw SiriFailure.existingDraft }
        let button = try unique("newChatButton", role: "AXButton", in: window)
        guard AXUIElementPerformAction(button,kAXPressAction as CFString) == .success else {
            throw SiriFailure.missingControls
        }
        let conversationDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            if let chat = try? unique("innerChatSessionView", in: window),
               let field = try? unique("promptViewTextField", role: "AXTextField", in: window),
               try userMessages(chat).isEmpty && string(field,kAXValueAttribute).isEmpty { break }
            try await pause(until: conversationDeadline)
        }
        let currentInput = try unique("promptViewTextField", role: "AXTextField", in: window)
        let prompt = try unique("promptView", in: window)
        guard try elements(prompt).contains(where: { CFEqual($0,currentInput) }) else { throw SiriFailure.missingControls }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(currentInput,kAXValueAttribute as CFString,&settable) == .success,
              settable.boolValue else { throw SiriFailure.missingControls }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(currentInput,&actions) == .success,
              (actions as? [String])?.contains("AXConfirm") == true else { throw SiriFailure.missingControls }
        destination = Destination(pid: identity.0, launchDate: identity.1, app: app, window: window,
                                  input: currentInput, chat: try unique("innerChatSessionView", in: window),
                                  selectedRows: try selectedRows(window))
    }

    func enter(_ message: String) async throws {
        guard let d = destination else { throw SiriFailure.unavailable }
        try await checkDestination(d, beforeSubmit: true)
        guard string(d.input,kAXValueAttribute).isEmpty else { throw SiriFailure.existingDraft }
        guard AXUIElementSetAttributeValue(d.input,kAXValueAttribute as CFString,message as CFString) == .success else {
            throw SiriFailure.textMismatch
        }
        text = message
        let inputDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while string(d.input,kAXValueAttribute) != message { try await pause(until: inputDeadline) }
    }

    func submit(_ message: String) async throws {
        guard let d = destination else { throw SiriFailure.unavailable }
        try await checkDestination(d, beforeSubmit: true)
        guard string(d.input,kAXValueAttribute) == message, text == message else { throw SiriFailure.textMismatch }
        try checkDeadline()
        guard AXUIElementPerformAction(d.input,"AXConfirm" as CFString) == .success else {
            throw SiriFailure.submissionUncertain
        }
    }

    func verify(_ message: String) async throws {
        guard let d = destination else { throw SiriFailure.submissionUncertain }
        try await checkDestination(d, beforeSubmit: false)
        let verificationDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            try await checkDestination(d, beforeSubmit: false)
            if try string(d.input,kAXValueAttribute).isEmpty && userMessages(d.chat) == [message] { return }
            try await pause(until: verificationDeadline)
        }
    }

    func finish() async {
        // Preserve uncertain drafts. Never delete conversations or overwrite concurrent user edits.
        destination = nil
        text = nil
    }

    @MainActor private static func openSiri() async throws -> (pid_t, Date?) {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.campo") else {
            throw SiriFailure.unavailable
        }
        let state = LaunchState()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            let result: Result<(pid_t, Date?), SiriFailure>
            if let app, error == nil, app.bundleIdentifier == "com.apple.campo" {
                result = .success((app.processIdentifier, app.launchDate))
            } else {
                result = .failure(.unavailable)
            }
            Task { @MainActor in state.result = result }
        }
        let limit = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            try Task.checkCancellation()
            if let result = state.result { return try result.get() }
            guard ContinuousClock.now < limit else { throw SiriFailure.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor private final class LaunchState {
        var result: Result<(pid_t, Date?), SiriFailure>?
    }
}
