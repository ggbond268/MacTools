import Foundation

protocol AIAssistantHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: AIAssistantHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse
        }

        return (data, httpResponse)
    }
}
