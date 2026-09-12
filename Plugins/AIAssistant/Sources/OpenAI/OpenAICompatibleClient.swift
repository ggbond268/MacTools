import Foundation
import MacToolsPluginKit

/// Abstraction over text-processing backends so the coordinator can be tested
/// with a fake client instead of a live HTTP session.
protocol AIProcessing: Sendable {
    func complete(
        prompt: String,
        systemPrompt: String?,
        configuration: OpenAICompatibleConfiguration,
        apiKey: String
    ) async throws -> AIProcessResult
}

struct OpenAICompatibleClient: AIProcessing, Sendable {
    private let httpClient: any AIAssistantHTTPClient
    private let timeout: TimeInterval
    private let localization: PluginLocalization

    init(
        httpClient: any AIAssistantHTTPClient = URLSession.shared,
        timeout: TimeInterval = 30,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.localization = localization
    }

    /// Processes arbitrary text through the given prompt and returns the model output,
    /// including an optional reasoning segment when the model provides one.
    func complete(
        prompt: String,
        systemPrompt: String?,
        configuration: OpenAICompatibleConfiguration,
        apiKey: String
    ) async throws -> AIProcessResult {
        var messages: [OpenAIChatCompletionsRequest.Message] = []
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(
                OpenAIChatCompletionsRequest.Message(role: "system", content: systemPrompt)
            )
        }
        messages.append(OpenAIChatCompletionsRequest.Message(role: "user", content: prompt))

        let requestBody = OpenAIChatCompletionsRequest(
            model: configuration.normalizedModel,
            messages: messages,
            temperature: configuration.temperature,
            reasoning: configuration.reasoningRequested,
            stream: false
        )

        var request = URLRequest(
            url: try configuration.endpointURL(),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: HTTPURLResponse

        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let error as OpenAICompatibleClientError {
            throw error
        } catch {
            AIAssistantLog.provider.error("completion request transport error")
            throw OpenAICompatibleClientError.requestFailed
        }

        guard (200 ... 299).contains(response.statusCode) else {
            let serverMessage = Self.extractErrorMessage(from: data)
            AIAssistantLog.provider.error(
                "completion request failed with status \(response.statusCode, privacy: .public): \(serverMessage ?? "none", privacy: .public)"
            )

            if response.statusCode == 401 || response.statusCode == 403 {
                throw OpenAICompatibleClientError.unauthorized(message: serverMessage)
            }

            let detail = serverMessage ?? "HTTP \(response.statusCode)"
            throw OpenAICompatibleClientError.requestFailed(message: detail)
        }

        let decoded = try decodeResponse(from: data)
        return AIProcessResult(
            providerTitle: localization.string("openAIClient.providerTitle", defaultValue: "AI 助手"),
            text: decoded.content,
            reasoningText: decoded.reasoningContent,
            sourceText: "",
            promptName: ""
        )
    }

    /// Fetches the list of available model IDs from the provider's `/models`
    /// endpoint. Returns an empty list if the provider returns no entries.
    func listModels(
        configuration: OpenAICompatibleConfiguration,
        apiKey: String
    ) async throws -> [String] {
        var request = URLRequest(
            url: try configuration.modelsEndpointURL(),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")

        let data: Data
        let response: HTTPURLResponse

        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let error as OpenAICompatibleClientError {
            throw error
        } catch {
            AIAssistantLog.provider.error("models request transport error")
            throw OpenAICompatibleClientError.requestFailed
        }

        guard (200 ... 299).contains(response.statusCode) else {
            let serverMessage = Self.extractErrorMessage(from: data)
            AIAssistantLog.provider.error(
                "models request failed with status \(response.statusCode, privacy: .public): \(serverMessage ?? "none", privacy: .public)"
            )

            if response.statusCode == 401 || response.statusCode == 403 {
                throw OpenAICompatibleClientError.unauthorized(message: serverMessage)
            }

            let detail = serverMessage ?? "HTTP \(response.statusCode)"
            throw OpenAICompatibleClientError.requestFailed(message: detail)
        }

        return try decodeModelsResponse(from: data)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObj = json["error"] as? [String: Any],
               let msg = errorObj["message"] as? String,
               !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return msg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let msg = json["message"] as? String,
               !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return msg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           text.count <= 400,
           !text.lowercased().contains("<html") {
            return text
        }
        return nil
    }

    private func decodeModelsResponse(from data: Data) throws -> [String] {
        let response: OpenAIModelsResponse

        do {
            response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        } catch {
            throw OpenAICompatibleClientError.parseFailed
        }

        let models = response.data
            .map(\.id)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return models
    }

    private func decodeResponse(from data: Data) throws -> (content: String, reasoningContent: String?) {
        let response: OpenAIChatCompletionsResponse

        do {
            response = try JSONDecoder().decode(OpenAIChatCompletionsResponse.self, from: data)
        } catch {
            throw OpenAICompatibleClientError.parseFailed
        }

        guard let content = response.choices.first?.message.content else {
            throw OpenAICompatibleClientError.parseFailed
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw OpenAICompatibleClientError.emptyResponse
        }

        let trimmedReasoning = response.choices.first?.message.reasoningContent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedContent, trimmedReasoning?.isEmpty == false ? trimmedReasoning : nil)
    }
}

enum OpenAICompatibleClientError: Error, Equatable, Sendable {
    case invalidResponse
    case requestFailed(message: String?)
    case unauthorized(message: String?)
    case emptyResponse
    case parseFailed

    static var requestFailed: Self { .requestFailed(message: nil) }
    static var unauthorized: Self { .unauthorized(message: nil) }
}

extension OpenAICompatibleClientError: LocalizedError {
    var errorDescription: String? {
        errorDescription()
    }

    func errorDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case let .requestFailed(message):
            if let message, !message.isEmpty {
                return message
            }
            return localization.string("openAIClient.error.requestFailed", defaultValue: "请求失败，请稍后重试")
        case let .unauthorized(message):
            if let message, !message.isEmpty {
                return message
            }
            return localization.string("openAIClient.error.unauthorized", defaultValue: "API Key 无效或无权限")
        case .invalidResponse:
            return localization.string("openAIClient.error.requestFailed", defaultValue: "请求失败，请稍后重试")
        case .emptyResponse:
            return localization.string("openAIClient.error.emptyResponse", defaultValue: "响应为空")
        case .parseFailed:
            return localization.string("openAIClient.error.parseFailed", defaultValue: "无法解析处理结果")
        }
    }
}

private struct OpenAIChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let reasoning: Bool?
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case reasoning
        case stream
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encode(stream, forKey: .stream)
    }
}

private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct OpenAIChatCompletionsResponse: Decodable {
    struct Message: Decodable {
        let content: String
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
        }
    }

    struct Choice: Decodable {
        let message: Message
    }

    let choices: [Choice]
}
