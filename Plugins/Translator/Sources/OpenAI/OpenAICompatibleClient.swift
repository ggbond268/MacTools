import Foundation

struct OpenAICompatibleClient: Sendable {
    private let httpClient: any TranslatorHTTPClient
    private let timeout: TimeInterval

    init(
        httpClient: any TranslatorHTTPClient = URLSession.shared,
        timeout: TimeInterval = 30
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection,
        configuration: OpenAICompatibleConfiguration,
        apiKey: String
    ) async throws -> TranslationResult {
        let sourceLanguageName = languageSelection.source?.promptName ?? "自动检测"
        let targetLanguageName = languageSelection.target.promptName
        let prompt = try TranslationPromptRenderer(template: configuration.promptTemplate).render(
            text: text,
            sourceLanguageName: sourceLanguageName,
            targetLanguageName: targetLanguageName
        )
        let requestBody = OpenAIChatCompletionsRequest(
            model: configuration.normalizedModel,
            messages: [
                OpenAIChatCompletionsRequest.Message(role: "user", content: prompt),
            ],
            temperature: 0.2,
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
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: HTTPURLResponse

        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let error as OpenAICompatibleClientError {
            throw error
        } catch {
            throw OpenAICompatibleClientError.requestFailed
        }

        guard (200 ... 299).contains(response.statusCode) else {
            throw OpenAICompatibleClientError.requestFailed
        }

        let content = try decodeContent(from: data)

        return TranslationResult(
            providerTitle: "翻译结果",
            text: content,
            sourceText: text,
            languageSelection: languageSelection
        )
    }

    private func decodeContent(from data: Data) throws -> String {
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

        return trimmedContent
    }
}

enum OpenAICompatibleClientError: Error, Equatable, Sendable {
    case invalidResponse
    case requestFailed
    case emptyResponse
    case parseFailed
}

extension OpenAICompatibleClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse, .requestFailed:
            return "请求失败，请稍后重试"
        case .emptyResponse:
            return "响应为空"
        case .parseFailed:
            return "无法解析翻译结果"
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
    let stream: Bool
}

private struct OpenAIChatCompletionsResponse: Decodable {
    struct Message: Decodable {
        let content: String
    }

    struct Choice: Decodable {
        let message: Message
    }

    let choices: [Choice]
}
