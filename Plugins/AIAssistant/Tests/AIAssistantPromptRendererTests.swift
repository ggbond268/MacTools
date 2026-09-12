import Foundation
import XCTest
@testable import AIAssistantPlugin

final class AIAssistantPromptRendererTests: XCTestCase {
    func testRendersTextPlaceholder() throws {
        let renderer = PromptRenderer(template: "请处理：{{text}}")

        let result = try renderer.render(text: "你好")

        XCTAssertEqual(result, "请处理：你好")
    }

    func testMissingTextPlaceholderThrows() {
        let renderer = PromptRenderer(template: "请处理这段文本")

        XCTAssertThrowsError(try renderer.render(text: "你好")) { error in
            XCTAssertEqual(error as? PromptRendererError, .missingTextPlaceholder)
        }
    }
}
