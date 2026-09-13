import Foundation

private final class AIUsageRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AIUsageClient: AIUsageFetching {
    let credentials: any AIUsageCredentialReading
    private let session: URLSession

    init(credentials: any AIUsageCredentialReading = AIUsageCredentialReader(), session: URLSession? = nil) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: AIUsageRedirectPolicy(), delegateQueue: nil)
        }
    }

    func fetch(_ provider: AIUsageProvider, allowsFileAccess: Bool, allowsKeychain: Bool) async -> AIUsageFetchResult {
        var identity: String?
        do {
            try Task.checkCancellation()
            let credential = try await credentials.read(provider, allowsFileAccess: allowsFileAccess, allowsKeychain: allowsKeychain, promptsForKeychain: false)
            identity = credential.identity
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: Self.request(provider, credential: credential))
            guard let response = response as? HTTPURLResponse else { throw AIUsageFailure.invalidResponse }
            try Self.validate(response, now: Date())
            guard response.expectedContentLength <= 1_048_576 else { throw AIUsageFailure.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw AIUsageFailure.invalidResponse }
                data.append(byte)
            }
            let snapshot = try AIUsageParser.parse(data, provider: provider, now: Date())
            return AIUsageFetchResult(credentialID: identity, result: .success(snapshot))
        } catch {
            return AIUsageFetchResult(credentialID: identity, result: .failure((error as? AIUsageFailure) ?? .network))
        }
    }

    func authorizeClaudeKeychain() async -> AIUsageFailure? {
        do {
            _ = try await credentials.read(.claude, allowsFileAccess: false, allowsKeychain: true, promptsForKeychain: true)
            return nil
        } catch {
            return (error as? AIUsageFailure) ?? .keychainPermission
        }
    }

    static func request(_ provider: AIUsageProvider, credential: AIUsageCredential) -> URLRequest {
        let endpoint = provider == .codex
            ? "https://chatgpt.com/backend-api/wham/usage"
            : "https://api.anthropic.com/api/oauth/usage"
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .codex {
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            if let accountID = credential.accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        } else {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    static func validate(_ response: HTTPURLResponse, now: Date) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw AIUsageFailure.expired
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let interval = Double(header) ?? formatter.date(from: header)?.timeIntervalSince(now) ?? 600
            throw AIUsageFailure.rateLimited(retryAfter: interval.isFinite ? max(600, min(interval, 86_400)) : 600)
        default: throw AIUsageFailure.server
        }
    }
}
