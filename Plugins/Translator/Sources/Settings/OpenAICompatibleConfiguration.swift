import Foundation
import MacToolsPluginKit

struct OpenAICompatibleConfiguration: Equatable, Sendable {
    static let defaultBaseURL = "https://api.openai.com"
    static let defaultModel = "gpt-5.4-mini"
    static let defaultPromptTemplate = """
    请将下面的文本从 {{source_language}} 翻译为 {{target_language}}，只返回译文。

    {{text}}
    """

    var baseURL: String
    var model: String
    var promptTemplate: String

    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        baseURL: String = Self.defaultBaseURL,
        model: String = Self.defaultModel,
        promptTemplate: String = Self.defaultPromptTemplate
    ) {
        self.baseURL = baseURL
        self.model = model
        self.promptTemplate = promptTemplate
    }

    @MainActor
    init(storage: PluginStorage) {
        self.init(
            baseURL: storage.string(forKey: TranslatorConstants.StorageKey.openAIBaseURL) ?? Self.defaultBaseURL,
            model: storage.string(forKey: TranslatorConstants.StorageKey.openAIModel) ?? Self.defaultModel,
            promptTemplate: storage.string(forKey: TranslatorConstants.StorageKey.openAIPromptTemplate) ?? Self.defaultPromptTemplate
        )
    }

    var validationError: OpenAICompatibleConfigurationError? {
        if normalizedBaseURL.isEmpty {
            return .blankBaseURL
        }

        guard let components = URLComponents(string: normalizedBaseURL),
              let host = components.host,
              !host.isEmpty,
              Self.isAllowedScheme(components.scheme, host: host)
        else {
            return .invalidBaseURL
        }

        if normalizedModel.isEmpty {
            return .blankModel
        }

        if !promptTemplate.contains("{{text}}") {
            return .missingTextPlaceholder
        }

        return nil
    }

    @MainActor
    func save(to storage: PluginStorage) {
        storage.set(normalizedBaseURL, forKey: TranslatorConstants.StorageKey.openAIBaseURL)
        storage.set(normalizedModel, forKey: TranslatorConstants.StorageKey.openAIModel)
        storage.set(promptTemplate, forKey: TranslatorConstants.StorageKey.openAIPromptTemplate)
    }

    func endpointURL() throws -> URL {
        if let validationError {
            throw validationError
        }

        guard var components = URLComponents(string: normalizedBaseURL),
              let host = components.host,
              !host.isEmpty,
              Self.isAllowedScheme(components.scheme, host: host)
        else {
            throw OpenAICompatibleConfigurationError.invalidBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = basePath.isEmpty ? [] : basePath.split(separator: "/").map(String.init)
        let completionPathComponents: [String]

        if pathComponents.last == "v1" {
            completionPathComponents = pathComponents + ["chat", "completions"]
        } else {
            completionPathComponents = pathComponents + ["v1", "chat", "completions"]
        }

        components.path = "/" + completionPathComponents.joined(separator: "/")

        guard let url = components.url else {
            throw OpenAICompatibleConfigurationError.invalidBaseURL
        }

        return url
    }

    private static func isAllowedScheme(_ scheme: String?, host: String) -> Bool {
        guard let scheme = scheme?.lowercased() else {
            return false
        }

        if scheme == "https" {
            return true
        }

        return scheme == "http" && isLoopbackHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalizedHost == "localhost"
            || isIPv4Loopback(normalizedHost)
            || normalizedHost == "::1"
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }

        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part),
                  (0...255).contains(value)
            else {
                return false
            }
            octets.append(value)
        }

        return octets.first == 127
    }
}

enum OpenAICompatibleConfigurationError: Error, Equatable, Sendable {
    case missingTextPlaceholder
    case blankBaseURL
    case invalidBaseURL
    case blankModel
}

extension OpenAICompatibleConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingTextPlaceholder:
            return "提示词必须包含 {{text}}。"
        case .blankBaseURL:
            return "Base URL 不能为空。"
        case .invalidBaseURL:
            return "Base URL 无效。"
        case .blankModel:
            return "模型不能为空。"
        }
    }
}
