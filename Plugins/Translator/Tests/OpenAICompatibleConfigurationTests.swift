import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class OpenAICompatibleConfigurationTests: XCTestCase {
    func testDefaultValues() {
        let configuration = OpenAICompatibleConfiguration()

        XCTAssertEqual(configuration.baseURL, "https://api.openai.com")
        XCTAssertEqual(configuration.model, "gpt-5.4-mini")
        XCTAssertTrue(configuration.promptTemplate.contains("{{source_language}}"))
        XCTAssertTrue(configuration.promptTemplate.contains("{{target_language}}"))
        XCTAssertTrue(configuration.promptTemplate.contains("{{text}}"))
    }

    func testEndpointAppendsChatCompletionsPath() throws {
        let configuration = OpenAICompatibleConfiguration(baseURL: "https://api.openai.com")

        XCTAssertEqual(
            try configuration.endpointURL().absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func testEndpointDoesNotDuplicateV1Path() throws {
        let configuration = OpenAICompatibleConfiguration(baseURL: "https://gateway.example.com/v1/")

        XCTAssertEqual(
            try configuration.endpointURL().absoluteString,
            "https://gateway.example.com/v1/chat/completions"
        )
    }

    func testPromptTemplateMissingTextIsInvalidWithExactMessage() {
        let configuration = OpenAICompatibleConfiguration(promptTemplate: "翻译 {{source_language}} 到 {{target_language}}")

        XCTAssertEqual(configuration.validationError?.localizedDescription, "提示词必须包含 {{text}}。")
    }

    func testBlankBaseURLIsInvalidWithExactMessage() {
        let configuration = OpenAICompatibleConfiguration(baseURL: "   \n  ")

        XCTAssertEqual(configuration.validationError?.localizedDescription, "Base URL 不能为空。")
    }

    func testMissingHostIsInvalidWithExactMessage() {
        let configurations = [
            OpenAICompatibleConfiguration(baseURL: "https:///v1"),
            OpenAICompatibleConfiguration(baseURL: "not-a-url"),
        ]

        for configuration in configurations {
            XCTAssertEqual(configuration.validationError?.localizedDescription, "Base URL 无效。")
        }
    }

    func testUnsupportedSchemeIsInvalidWithExactMessage() {
        let configuration = OpenAICompatibleConfiguration(baseURL: "ftp://example.com")

        XCTAssertEqual(configuration.validationError?.localizedDescription, "Base URL 无效。")
    }

    func testRemoteHTTPBaseURLIsInvalidWithExactMessage() {
        let configuration = OpenAICompatibleConfiguration(baseURL: "http://gateway.example.com")

        XCTAssertEqual(configuration.validationError?.localizedDescription, "Base URL 无效。")
    }

    func testLoopbackHTTPBaseURLIsAllowedForLocalGateways() throws {
        let configurations = [
            OpenAICompatibleConfiguration(baseURL: "http://localhost:11434"),
            OpenAICompatibleConfiguration(baseURL: "http://127.0.0.1:11434"),
            OpenAICompatibleConfiguration(baseURL: "http://127.0.0.2:11434"),
            OpenAICompatibleConfiguration(baseURL: "http://127.1.2.3:11434"),
            OpenAICompatibleConfiguration(baseURL: "http://[::1]:11434"),
        ]

        for configuration in configurations {
            XCTAssertNil(configuration.validationError)
            XCTAssertTrue(try configuration.endpointURL().absoluteString.contains("/v1/chat/completions"))
        }
    }

    func testHTTPBaseURLWith127PrefixButNonIPv4HostIsInvalidWithExactMessage() {
        let configuration = OpenAICompatibleConfiguration(baseURL: "http://127.example.com")

        XCTAssertEqual(configuration.validationError?.localizedDescription, "Base URL 无效。")
    }

    func testEndpointThrowsSpecificValidationErrorBeforeBuildingURL() {
        let configurations: [(OpenAICompatibleConfiguration, OpenAICompatibleConfigurationError)] = [
            (OpenAICompatibleConfiguration(baseURL: "   \n  "), .blankBaseURL),
            (OpenAICompatibleConfiguration(model: " \n\t "), .blankModel),
            (OpenAICompatibleConfiguration(promptTemplate: "翻译 {{source_language}} 到 {{target_language}}"), .missingTextPlaceholder),
        ]

        for (configuration, expectedError) in configurations {
            XCTAssertThrowsError(try configuration.endpointURL()) { error in
                XCTAssertEqual(error as? OpenAICompatibleConfigurationError, expectedError)
            }
        }
    }

    func testWhitespaceOnlyModelIsInvalidWithExactMessage() {
        let configuration = OpenAICompatibleConfiguration(model: " \n\t ")

        XCTAssertEqual(configuration.validationError?.localizedDescription, "模型不能为空。")
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
