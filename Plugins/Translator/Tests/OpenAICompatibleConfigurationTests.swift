import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class OpenAICompatibleConfigurationTests: XCTestCase {
    func testEndpointNormalizationPreservesProviderPaths() throws {
        let cases = [
            ("https://api.openai.com", "https://api.openai.com/v1/chat/completions"),
            ("https://gateway.example.com/v1/", "https://gateway.example.com/v1/chat/completions"),
            ("https://gateway.example.com/openai/v1/chat/completions", "https://gateway.example.com/openai/v1/chat/completions"),
            ("https://provider.example.com/api/v4/chat/completions", "https://provider.example.com/api/v4/chat/completions"),
        ]
        for (baseURL, expected) in cases {
            let configuration = OpenAICompatibleConfiguration(baseURL: baseURL)
            XCTAssertEqual(try configuration.endpointURL().absoluteString, expected, baseURL)
        }
    }

    func testEndpointRejectsInvalidOrInsecureConfiguration() {
        let cases: [(String, OpenAICompatibleConfiguration, OpenAICompatibleConfigurationError)] = [
            ("missing text placeholder", .init(promptTemplate: "Translate {{source_language}}"), .missingTextPlaceholder),
            ("blank URL", .init(baseURL: "  "), .blankBaseURL),
            ("missing host", .init(baseURL: "https:///v1"), .invalidBaseURL),
            ("malformed URL", .init(baseURL: "not-a-url"), .invalidBaseURL),
            ("unsupported scheme", .init(baseURL: "ftp://example.com"), .invalidBaseURL),
            ("insecure remote endpoint", .init(baseURL: "http://gateway.example.com"), .invalidBaseURL),
            ("blank model", .init(model: "  "), .blankModel),
        ]
        for (label, configuration, expected) in cases {
            XCTAssertEqual(configuration.validationError, expected, label)
            XCTAssertThrowsError(try configuration.endpointURL(), label) { error in
                XCTAssertEqual(error as? OpenAICompatibleConfigurationError, expected, label)
            }
        }
    }

    func testLoopbackHTTPBaseURLIsAllowedForLocalGateways() throws {
        for baseURL in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            let configuration = OpenAICompatibleConfiguration(baseURL: baseURL)
            XCTAssertNil(configuration.validationError, baseURL)
            XCTAssertTrue(try configuration.endpointURL().absoluteString.contains("/v1/chat/completions"), baseURL)
        }
    }

    func testSaveTrimsBaseURLAndModelButPreservesPromptTemplate() {
        let storage = TranslatorInMemoryPluginStorage()
        let promptTemplate = "  翻译：{{text}}  "
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "  https://gateway.example.com/v1/  ",
            model: "  gpt-test  ",
            promptTemplate: promptTemplate
        )

        configuration.save(to: storage)

        XCTAssertEqual(storage.string(forKey: "translator.openai.base-url"), "https://gateway.example.com/v1/")
        XCTAssertEqual(storage.string(forKey: "translator.openai.model"), "gpt-test")
        XCTAssertEqual(storage.string(forKey: "translator.openai.prompt-template"), promptTemplate)
    }
}
