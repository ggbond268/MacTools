import Foundation
import XCTest
@testable import AIAssistantPlugin

final class AIAssistantOpenAICompatibleConfigurationTests: XCTestCase {
    func testDefaultValues() {
        let configuration = OpenAICompatibleConfiguration()

        XCTAssertEqual(configuration.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(configuration.model, "deepseek-v4-flash")
        XCTAssertEqual(configuration.temperature, 0.7, accuracy: 0.0001)
        XCTAssertNil(configuration.reasoningRequested)
        XCTAssertNil(configuration.validationError)
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

    func testEndpointKeepsFullChatCompletionsPath() throws {
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "https://gateway.example.com/openai/v1/chat/completions"
        )

        XCTAssertEqual(
            try configuration.endpointURL().absoluteString,
            "https://gateway.example.com/openai/v1/chat/completions"
        )
    }

    func testBlankBaseURLIsInvalid() {
        let configuration = OpenAICompatibleConfiguration(baseURL: "   \n  ")

        XCTAssertEqual(configuration.validationError, .blankBaseURL)
    }

    func testMissingHostIsInvalid() {
        let configuration = OpenAICompatibleConfiguration(baseURL: "not-a-url")

        XCTAssertEqual(configuration.validationError, .invalidBaseURL)
    }

    func testRemoteHTTPBaseURLIsInvalid() {
        let configuration = OpenAICompatibleConfiguration(baseURL: "http://gateway.example.com")

        XCTAssertEqual(configuration.validationError, .invalidBaseURL)
    }

    func testLoopbackHTTPBaseURLIsAllowed() throws {
        let configurations = [
            OpenAICompatibleConfiguration(baseURL: "http://localhost:11434"),
            OpenAICompatibleConfiguration(baseURL: "http://127.0.0.1:11434"),
        ]

        for configuration in configurations {
            XCTAssertNil(configuration.validationError)
            XCTAssertTrue(try configuration.endpointURL().absoluteString.contains("/v1/chat/completions"))
        }
    }

    func testPrivateNetworkHTTPBaseURLIsAllowed() throws {
        let configurations = [
            OpenAICompatibleConfiguration(baseURL: "http://172.29.227.37:50731"),
            OpenAICompatibleConfiguration(baseURL: "http://10.0.0.5:8080"),
            OpenAICompatibleConfiguration(baseURL: "http://192.168.1.10:11434"),
        ]

        for configuration in configurations {
            XCTAssertNil(configuration.validationError)
            XCTAssertTrue(try configuration.endpointURL().absoluteString.contains("/v1/chat/completions"))
        }
    }

    func testNonPrivateHTTPBaseURLIsInvalid() {
        let configurations = [
            OpenAICompatibleConfiguration(baseURL: "http://8.8.8.8:8080"),
            OpenAICompatibleConfiguration(baseURL: "http://172.32.0.1:8080"),
            OpenAICompatibleConfiguration(baseURL: "http://192.169.0.1:8080"),
        ]

        for configuration in configurations {
            XCTAssertEqual(configuration.validationError, .invalidBaseURL)
        }
    }

    func testWhitespaceOnlyModelIsInvalid() {
        let configuration = OpenAICompatibleConfiguration(model: " \n\t ")

        XCTAssertEqual(configuration.validationError, .blankModel)
    }

    func testModelsEndpointAppendsModelsPath() throws {
        let configuration = OpenAICompatibleConfiguration(baseURL: "https://api.openai.com")

        XCTAssertEqual(
            try configuration.modelsEndpointURL().absoluteString,
            "https://api.openai.com/v1/models"
        )
    }

    func testModelsEndpointDoesNotDuplicateV1Path() throws {
        let configuration = OpenAICompatibleConfiguration(baseURL: "https://gateway.example.com/v1/")

        XCTAssertEqual(
            try configuration.modelsEndpointURL().absoluteString,
            "https://gateway.example.com/v1/models"
        )
    }

    func testModelsEndpointReplacesChatCompletionsPath() throws {
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "https://gateway.example.com/openai/v1/chat/completions"
        )

        XCTAssertEqual(
            try configuration.modelsEndpointURL().absoluteString,
            "https://gateway.example.com/openai/v1/models"
        )
    }
}
