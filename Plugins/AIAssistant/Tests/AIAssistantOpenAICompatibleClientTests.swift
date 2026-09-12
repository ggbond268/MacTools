import Foundation
import XCTest
@testable import AIAssistantPlugin

final class AIAssistantOpenAICompatibleClientTests: XCTestCase {
    func testBuildsRequestAndParsesResult() async throws {
        let recorder = RequestRecorder()
        let httpClient = StubHTTPClient(
            recorder: recorder,
            result: .success((
                Self.responsePayload(content: "  你好  "),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "https://api.openai.com",
            model: "gpt-test",
            temperature: 0.3
        )

        let result = try await client.complete(
            prompt: "请处理：Hello",
            systemPrompt: "你是助手",
            configuration: configuration,
            apiKey: "test-key"
        )

        XCTAssertEqual(result.text, "你好")
        XCTAssertNil(result.reasoningText)

        let recordedRequests = await recorder.requests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try Self.requestBody(from: request)
        XCTAssertEqual(body.model, "gpt-test")
        XCTAssertEqual(body.stream, false)
        XCTAssertEqual(body.temperature, 0.3, accuracy: 0.0001)
        XCTAssertNil(body.reasoning)
        XCTAssertEqual(body.messages.count, 2)
        XCTAssertEqual(body.messages.first?.role, "system")
        XCTAssertEqual(body.messages.first?.content, "你是助手")
        XCTAssertEqual(body.messages.last?.role, "user")
        XCTAssertEqual(body.messages.last?.content, "请处理：Hello")
    }

    func testOmitsEmptySystemPrompt() async throws {
        let recorder = RequestRecorder()
        let httpClient = StubHTTPClient(
            recorder: recorder,
            result: .success((
                Self.responsePayload(content: "你好"),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)

        _ = try await client.complete(
            prompt: "请处理",
            systemPrompt: "   ",
            configuration: OpenAICompatibleConfiguration(),
            apiKey: "test-key"
        )

        let recordedRequests = await recorder.requests
        let request = try XCTUnwrap(recordedRequests.first)
        let body = try Self.requestBody(from: request)
        XCTAssertEqual(body.messages.count, 1)
        XCTAssertEqual(body.messages.first?.role, "user")
    }

    func testEncodesRequestedReasoningField() async throws {
        let recorder = RequestRecorder()
        let httpClient = StubHTTPClient(
            recorder: recorder,
            result: .success((
                Self.responsePayload(content: "最终结果", reasoningContent: "思考过程"),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)
        let configuration = OpenAICompatibleConfiguration(reasoningRequested: true)

        let result = try await client.complete(
            prompt: "请处理",
            systemPrompt: nil,
            configuration: configuration,
            apiKey: "test-key"
        )

        XCTAssertEqual(result.text, "最终结果")
        XCTAssertEqual(result.reasoningText, "思考过程")

        let recordedRequests = await recorder.requests
        let request = try XCTUnwrap(recordedRequests.first)
        let body = try Self.requestBody(from: request)
        XCTAssertEqual(body.reasoning, true)
    }

    func testOmitsReasoningFieldWhenNotRequested() async throws {
        let recorder = RequestRecorder()
        let httpClient = StubHTTPClient(
            recorder: recorder,
            result: .success((
                Self.responsePayload(content: "你好"),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)

        _ = try await client.complete(
            prompt: "请处理",
            systemPrompt: nil,
            configuration: OpenAICompatibleConfiguration(),
            apiKey: "test-key"
        )

        let recordedRequests = await recorder.requests
        let request = try XCTUnwrap(recordedRequests.first)
        let body = try Self.requestBody(from: request)
        XCTAssertNil(body.reasoning)
    }

    func testParsesReasoningContent() async throws {
        let httpClient = StubHTTPClient(
            recorder: RequestRecorder(),
            result: .success((
                Self.responsePayload(content: "最终结果", reasoningContent: "思考过程"),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)

        let result = try await client.complete(
            prompt: "请处理",
            systemPrompt: nil,
            configuration: OpenAICompatibleConfiguration(),
            apiKey: "test-key"
        )

        XCTAssertEqual(result.text, "最终结果")
        XCTAssertEqual(result.reasoningText, "思考过程")
    }

    func testListModelsFetchesAndParsesIDs() async throws {
        let recorder = RequestRecorder()
        let httpClient = StubHTTPClient(
            recorder: recorder,
            result: .success((
                Data(
                    """
                    {
                      "object": "list",
                      "data": [
                        { "id": "gpt-4o-mini" },
                        { "id": "  gpt-4o  " },
                        { "id": "   " }
                      ]
                    }
                    """.utf8
                ),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)

        let models = try await client.listModels(
            configuration: OpenAICompatibleConfiguration(baseURL: "https://api.openai.com"),
            apiKey: "test-key"
        )

        XCTAssertEqual(models, ["gpt-4o-mini", "gpt-4o"])

        let recordedRequests = await recorder.requests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testListModels401MapsToUnauthorized() async {
        let client = OpenAICompatibleClient(
            httpClient: StubHTTPClient(
                recorder: RequestRecorder(),
                result: .success((Data("{}".utf8), Self.httpResponse(statusCode: 401)))
            )
        )

        do {
            _ = try await client.listModels(
                configuration: OpenAICompatibleConfiguration(),
                apiKey: "test-key"
            )
            XCTFail("Expected listModels to throw")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleClientError, .unauthorized)
        }
    }

    func testListModelsMalformedPayloadMapsToParseFailure() async {
        let client = OpenAICompatibleClient(
            httpClient: StubHTTPClient(
                recorder: RequestRecorder(),
                result: .success((Data(#"{"object":"list"}"#.utf8), Self.httpResponse(statusCode: 200)))
            )
        )

        do {
            _ = try await client.listModels(
                configuration: OpenAICompatibleConfiguration(),
                apiKey: "test-key"
            )
            XCTFail("Expected listModels to throw")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleClientError, .parseFailed)
        }
    }

    func testHTTP401MapsToUnauthorized() async {
        await assertError(
            result: .success((Data("{}".utf8), Self.httpResponse(statusCode: 401))),
            expected: .unauthorized
        )
    }

    func testHTTP404ExtractsServerErrorDetail() async {
        let errorPayload = Data(#"{"error":{"message":"The model 'deepseek-v4-flash' does not exist","code":"model_not_found"}}"#.utf8)
        await assertError(
            result: .success((errorPayload, Self.httpResponse(statusCode: 404))),
            expected: .requestFailed(message: "The model 'deepseek-v4-flash' does not exist")
        )
    }

    func testEmptyResponseContentMapsToEmptyResponse() async {
        await assertError(
            result: .success((
                Self.responsePayload(content: " \n\t "),
                Self.httpResponse(statusCode: 200)
            )),
            expected: .emptyResponse
        )
    }

    func testMalformedPayloadMapsToParseFailure() async {
        await assertError(
            result: .success((Data(#"{"choices":[]}"#.utf8), Self.httpResponse(statusCode: 200))),
            expected: .parseFailed
        )
    }

    // MARK: - Helpers

    private static func responsePayload(content: String, reasoningContent: String? = nil) -> Data {
        if let reasoningContent {
            return Data(
                """
                {
                  "choices": [
                    {
                      "message": {
                        "content": \(String(reflecting: content)),
                        "reasoning_content": \(String(reflecting: reasoningContent))
                      }
                    }
                  ]
                }
                """.utf8
            )
        }

        return Data(
            """
            {
              "choices": [
                {
                  "message": {
                    "content": \(String(reflecting: content))
                  }
                }
              ]
            }
            """.utf8
        )
    }

    private static func httpResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func requestBody(from request: URLRequest) throws -> RequestBody {
        let data = try XCTUnwrap(request.httpBody)
        return try JSONDecoder().decode(RequestBody.self, from: data)
    }

    private func assertError(
        result: Result<(Data, HTTPURLResponse), Error>,
        expected: OpenAICompatibleClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let client = OpenAICompatibleClient(
            httpClient: StubHTTPClient(recorder: RequestRecorder(), result: result)
        )

        do {
            _ = try await client.complete(
                prompt: "请处理",
                systemPrompt: nil,
                configuration: OpenAICompatibleConfiguration(),
                apiKey: "test-key"
            )
            XCTFail("Expected complete to throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleClientError, expected, file: file, line: line)
        }
    }
}

private actor RequestRecorder {
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        storedRequests
    }

    func record(_ request: URLRequest) {
        storedRequests.append(request)
    }
}

private struct StubHTTPClient: AIAssistantHTTPClient {
    let recorder: RequestRecorder
    let result: Result<(Data, HTTPURLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder.record(request)
        return try result.get()
    }
}

private struct RequestBody: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let reasoning: Bool?
    let stream: Bool
}
