import Foundation
import MacToolsPluginKit

/// Shared user-facing error text for the AI Assistant plugin.
enum AIAssistantUserFacingMessage {
    /// Maps an error to a concise, localized message suitable for the result panel
    /// and settings save path.
    static func message(for error: Error, localization: PluginLocalization) -> String {
        if let error = error as? OpenAICompatibleClientError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? OpenAICompatibleConfigurationError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? PromptRendererError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? AIAssistantSecretStoreError {
            return error.errorDescription(localization: localization)
        }
        if let error = error as? AIAssistantProviderProfileValidationError {
            return error.errorDescription(localization: localization)
        }
        return error.localizedDescription
    }
}
