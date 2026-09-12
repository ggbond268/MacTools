import Foundation

// Only phase/error categories cross into presentation; prompts stay in the active operation.
enum SiriPhase: String, Sendable {
    case idle, opening, preparing, entering, submitting, verifying, sent, failed, uncertain, cancelled
}

enum SiriFailure: Error, Equatable {
    case unavailable, permission, missingControls, ambiguousWindow, existingDraft, destinationChanged
    case textMismatch, timedOut, submissionUncertain
}

protocol SiriClient: Sendable {
    func prepareNewConversation() async throws
    func enter(_ message: String) async throws
    func submit(_ message: String) async throws
    func verify(_ message: String) async throws
    func finish() async
}
