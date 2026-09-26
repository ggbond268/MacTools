import Foundation
import XCTest
@testable import AIAssistantPlugin

@MainActor
final class AIAssistantProviderProfileTests: XCTestCase {
    func testDefaultValues() {
        let profile = AIAssistantProviderProfile.defaultProfile()

        XCTAssertEqual(profile.id, "default")
        XCTAssertTrue(profile.isEnabled)
        XCTAssertEqual(profile.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(profile.model, "deepseek-flash")
        XCTAssertEqual(profile.temperature, 0.7, accuracy: 0.0001)
        XCTAssertFalse(profile.enableReasoning)
    }

    func testConfigurationCarriesTemperatureAndReasoning() {
        let profile = AIAssistantProviderProfile(
            name: "服务",
            baseURL: "https://api.example.com",
            model: "gpt",
            temperature: 0.9,
            enableReasoning: true
        )

        XCTAssertEqual(profile.configuration.temperature, 0.9, accuracy: 0.0001)
        XCTAssertEqual(profile.configuration.reasoningRequested, true)
    }

    func testValidation() {
        let valid = AIAssistantProviderProfile(name: "服务", baseURL: "https://api.example.com", model: "gpt")
        XCTAssertNil(valid.validationError)

        let blankName = AIAssistantProviderProfile(name: "  ", baseURL: "https://api.example.com", model: "gpt")
        XCTAssertEqual(blankName.validationError, .blankName)

        let invalidConfig = AIAssistantProviderProfile(name: "服务", baseURL: "ftp://x", model: "gpt")
        XCTAssertEqual(invalidConfig.validationError, .configuration(.invalidBaseURL))
    }

    func testStoreLoadsCustomModelWithoutOverwriting() throws {
        let storage = AIAssistantInMemoryPluginStorage()
        let store = AIAssistantProviderProfileStore(storage: storage)
        let profile = AIAssistantProviderProfile(
            name: "AI 服务",
            baseURL: "https://api.example.com/v1",
            model: "deepseek-v4-flash"
        )
        try store.saveProfiles([profile])

        let loaded = store.loadProfiles()
        XCTAssertEqual(loaded.first?.model, "deepseek-v4-flash")
    }
}
