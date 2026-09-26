import XCTest
@testable import AIAssistantPlugin

@MainActor
final class AIAssistantPromptEditorTests: XCTestCase {
    private let first = AIAssistantPrompt(id: "first", name: "First", template: "{{text}}", isEnabled: true)
    private let second = AIAssistantPrompt(id: "second", name: "Second", template: "{{text}}", isEnabled: true)

    func testOtherActionsAndCancelNeverPersistDrafts() {
        var saved: [AIAssistantPrompt] = []
        let editor = AIAssistantPromptEditor(prompts: [first, second], persist: { saved = $0; return nil },
            makePrompt: { _ in AIAssistantPrompt(id: "new", name: "New", template: "{{text}}", isEnabled: true) })
        editor.beginEditing(first.id)
        editor.updateDraft(first.id, keyPath: \.template, value: "Unsaved")
        editor.addPrompt()
        XCTAssertTrue(saved.isEmpty)
        editor.movePrompt(second.id, offset: -1)
        editor.setEnabled(second.id, false)
        XCTAssertEqual(saved.map(\.id), [second.id, first.id])
        XCTAssertFalse(saved[0].isEnabled)
        XCTAssertEqual(saved[1].template, first.template)
        editor.cancel(first.id)
        editor.cancel("new")
        // A late control callback after cancellation must not edit another row.
        editor.updateDraft("new", keyPath: \.name, value: "Late callback")
        XCTAssertEqual(editor.prompts, saved)
        XCTAssertTrue(editor.promptEditDrafts.isEmpty)
    }

    func testRejectedSavePreservesDraftAndSuccessfulRetryCommitsOnlyThatDraft() {
        var saved: [AIAssistantPrompt] = []
        let editor = AIAssistantPromptEditor(prompts: [first, second], persist: { prompts in
            guard prompts.allSatisfy({ !$0.isEnabled || $0.template.contains("{{text}}") }) else { return "Invalid template" }
            saved = prompts
            return nil
        }, makePrompt: { _ in self.first })
        editor.beginEditing(first.id)
        editor.beginEditing(second.id)
        editor.updateDraft(first.id, keyPath: \.template, value: "Invalid")
        editor.updateDraft(second.id, keyPath: \.name, value: "Other draft")
        editor.save(first.id)
        XCTAssertTrue(editor.isEditing(first.id))
        XCTAssertEqual(editor.promptEditDrafts[first.id]?.template, "Invalid")
        XCTAssertNotNil(editor.message)
        XCTAssertEqual(editor.prompts, [first, second])
        XCTAssertTrue(saved.isEmpty)
        editor.updateDraft(first.id, keyPath: \.template, value: "Fixed {{text}}")
        editor.save(first.id)
        XCTAssertFalse(editor.isEditing(first.id))
        XCTAssertTrue(editor.isEditing(second.id))
        XCTAssertNil(editor.message)
        XCTAssertEqual(saved[0].template, "Fixed {{text}}")
        XCTAssertEqual(saved[1], second)
    }

    func testRejectedToggleDoesNotLeakIntoLaterSaves() {
        var invalid = first
        invalid.isEnabled = false
        invalid.template = "No placeholder"
        let editor = AIAssistantPromptEditor(prompts: [invalid], persist: { prompts in
            prompts.contains { $0.isEnabled && !$0.template.contains("{{text}}") } ? "Invalid" : nil
        }, makePrompt: { _ in self.second })
        editor.setEnabled(invalid.id, true)
        XCTAssertFalse(editor.prompts[0].isEnabled)
        XCTAssertNotNil(editor.message)
        editor.addPrompt()
        editor.save(second.id)
        XCTAssertFalse(editor.isEditing(second.id))
        XCTAssertEqual(editor.prompts.count, 2)
        XCTAssertFalse(editor.prompts[0].isEnabled)
    }
}
