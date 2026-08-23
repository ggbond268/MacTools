import CryptoKit
import Foundation
import MacToolsPluginKit
import UniformTypeIdentifiers

struct R2UploadResult: Equatable, Sendable {
    let objectKey: String
    let url: URL?
}

protocol R2Uploading: Sendable {
    func upload(
        fileURL: URL,
        objectName: String?,
        configuration: R2Configuration,
        secretAccessKey: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> R2UploadResult
}

protocol R2ObjectChecking: Sendable {
    func objectExists(
        objectName: String,
        configuration: R2Configuration,
        secretAccessKey: String
    ) async throws -> Bool
}

protocol R2HTTPObjectChecking: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

protocol R2HTTPUploading: Sendable {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, URLResponse)
}

struct R2UploadService: R2Uploading, R2ObjectChecking {
    private let httpClient: any R2HTTPUploading
    private let objectCheckClient: any R2HTTPObjectChecking
    private let now: @Sendable () -> Date

    init(
        httpClient: any R2HTTPUploading = R2URLSessionHTTPUploader(),
        objectCheckClient: any R2HTTPObjectChecking = R2URLSessionHTTPObjectChecker(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.httpClient = httpClient
        self.objectCheckClient = objectCheckClient
        self.now = now
    }

    func objectExists(
        objectName: String,
        configuration: R2Configuration,
        secretAccessKey: String
    ) async throws -> Bool {
        guard configuration.isComplete else {
            throw R2UploadError.incompleteConfiguration
        }
        let objectKey = try makeObjectKey(
            objectName: objectName,
            configuration: configuration
        )
        let canonicalURI = R2S3URIEncoder.canonicalURI(
            bucket: configuration.bucket,
            objectKey: objectKey
        )
        guard let requestURL = R2S3URIEncoder.requestURL(
            accountID: configuration.accountID,
            canonicalURI: canonicalURI
        ) else {
            throw R2UploadError.invalidConfiguration
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "HEAD"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        try R2RequestSigner.sign(
            request: &request,
            canonicalURI: canonicalURI,
            payloadHash: "UNSIGNED-PAYLOAD",
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: secretAccessKey,
            date: now()
        )
        let (_, response) = try await objectCheckClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw R2UploadError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return true
        case 404:
            return false
        default:
            throw R2UploadError.httpStatus(httpResponse.statusCode)
        }
    }

    func upload(
        fileURL: URL,
        objectName: String? = nil,
        configuration: R2Configuration,
        secretAccessKey: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> R2UploadResult {
        guard configuration.isComplete else {
            throw R2UploadError.incompleteConfiguration
        }
        guard fileURL.isFileURL else {
            throw R2UploadError.invalidFile
        }
        guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw R2UploadError.invalidFile
        }

        let objectKey = try makeObjectKey(
            fileName: fileURL.lastPathComponent,
            objectName: objectName,
            configuration: configuration
        )
        let canonicalURI = R2S3URIEncoder.canonicalURI(
            bucket: configuration.bucket,
            objectKey: objectKey
        )
        guard let requestURL = R2S3URIEncoder.requestURL(
            accountID: configuration.accountID,
            canonicalURI: canonicalURI
        ) else {
            throw R2UploadError.invalidConfiguration
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue(contentType(for: fileURL), forHTTPHeaderField: "Content-Type")
        try R2RequestSigner.sign(
            request: &request,
            canonicalURI: canonicalURI,
            payloadHash: "UNSIGNED-PAYLOAD",
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: secretAccessKey,
            date: now()
        )

        let (_, response) = try await httpClient.upload(
            for: request,
            fromFile: fileURL,
            progress: progress
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw R2UploadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw R2UploadError.httpStatus(httpResponse.statusCode)
        }

        return R2UploadResult(
            objectKey: objectKey,
            url: R2PublicURLValidator.objectURL(
                objectKey: objectKey,
                baseURLString: configuration.publicBaseURL
            )
        )
    }

    private func makeObjectKey(
        fileName: String,
        objectName: String?,
        configuration: R2Configuration
    ) throws -> String {
        let resolvedName: String
        if let objectName {
            resolvedName = try R2ObjectNameValidator.normalized(objectName)
        } else {
            resolvedName = fileName
        }

        return try makeObjectKey(objectName: resolvedName, configuration: configuration)
    }

    private func makeObjectKey(
        objectName: String,
        configuration: R2Configuration
    ) throws -> String {
        let normalizedName = try R2ObjectNameValidator.normalized(objectName)
        let prefix = try R2ObjectPrefixValidator.normalizedPrefix(
            from: configuration.objectPrefix
        )
        return prefix.isEmpty ? normalizedName : "\(prefix)/\(normalizedName)"
    }

    private func contentType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}

enum R2ObjectNameValidator {
    static func normalized(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty
            && trimmed != "."
            && trimmed != ".."
            && !trimmed.contains("/")
            && !trimmed.contains("\0") else {
            throw R2UploadError.invalidObjectName
        }
        return trimmed
    }

    static func isValid(_ value: String) -> Bool {
        (try? normalized(value)) != nil
    }
}

enum R2ObjectPrefixValidator {
    static func normalizedPrefix(from value: String) throws -> String {
        let segments = value.split(separator: "/").map(String.init)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else {
            throw R2UploadError.invalidObjectPrefix
        }
        return segments.joined(separator: "/")
    }

    static func isValid(_ value: String) -> Bool {
        (try? normalizedPrefix(from: value)) != nil
    }
}

enum R2S3URIEncoder {
    static func canonicalURI(bucket: String, objectKey: String) -> String {
        "/\(encode(bucket, preservingSlashes: false))/\(encode(objectKey, preservingSlashes: true))"
    }

    static func requestURL(accountID: String, canonicalURI: String) -> URL? {
        guard !accountID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(accountID).r2.cloudflarestorage.com"
        components.percentEncodedPath = canonicalURI
        return components.url
    }

    static func encode(_ value: String, preservingSlashes: Bool) -> String {
        value.utf8.map { byte in
            if isUnreserved(byte) || (preservingSlashes && byte == 0x2F) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || [0x2D, 0x2E, 0x5F, 0x7E].contains(byte)
    }
}

enum R2PublicURLValidator {
    static func baseURL(from value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        return components.url
    }

    static func objectURL(objectKey: String, baseURLString: String) -> URL? {
        baseURL(from: baseURLString)?.appendingPathComponent(objectKey)
    }
}

enum R2RequestSigner {
    static func sign(
        request: inout URLRequest,
        canonicalURI: String,
        payloadHash: String,
        accessKeyID: String,
        secretAccessKey: String,
        date: Date
    ) throws {
        guard let url = request.url, let host = url.host else {
            throw R2UploadError.invalidConfiguration
        }

        let timestamp = formatted(date, pattern: "yyyyMMdd'T'HHmmss'Z'")
        let day = formatted(date, pattern: "yyyyMMdd")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        let contentType = request.value(forHTTPHeaderField: "Content-Type")
            ?? "application/octet-stream"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(timestamp)\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            request.httpMethod ?? "PUT",
            canonicalURI,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/auto/s3/aws4_request"
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(canonicalRequestHash)"

        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), value: day)
        let regionKey = hmac(key: dateKey, value: "auto")
        let serviceKey = hmac(key: regionKey, value: "s3")
        let signingKey = hmac(key: serviceKey, value: "aws4_request")
        let signature = hmac(key: signingKey, value: stringToSign).hexString
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func hmac(key: Data, value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: SymmetricKey(data: key)
        ))
    }

    private static func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct R2URLSessionHTTPUploader: R2HTTPUploading {
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        try await R2URLSessionUploadOperation(progress: progress).start(
            request: request,
            fileURL: fileURL
        )
    }
}

struct R2URLSessionHTTPObjectChecker: R2HTTPObjectChecking {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await session.data(for: request)
    }
}

final class R2URLSessionUploadOperation: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private let onTaskResume: @Sendable () -> Void

    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionUploadTask?
    private var session: URLSession?
    private var response: URLResponse?
    private var data = Data()
    private var isCancelled = false

    init(
        progress: @escaping @Sendable (Double) -> Void,
        onTaskResume: @escaping @Sendable () -> Void = {}
    ) {
        self.progress = progress
        self.onTaskResume = onTaskResume
    }

    func start(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(
                    configuration: .ephemeral,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.uploadTask(with: request, fromFile: fileURL)
                let didResume = lock.withLock {
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    guard !isCancelled else { return false }
                    task.resume()
                    return true
                }

                guard didResume else {
                    task.cancel()
                    return
                }
                onTaskResume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progress(min(1, max(0, fraction)))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock {
            self.response = response
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.withLock {
            self.data.append(data)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let completion = lock.withLock { () -> (
            CheckedContinuation<(Data, URLResponse), Error>?,
            Data,
            URLResponse?
        ) in
            let continuation = self.continuation
            self.continuation = nil
            self.task = nil
            self.session = nil
            return (continuation, data, response)
        }
        session.finishTasksAndInvalidate()

        guard let continuation = completion.0 else { return }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let response = completion.2 else {
            continuation.resume(throwing: R2UploadError.invalidResponse)
            return
        }
        progress(1)
        continuation.resume(returning: (completion.1, response))
    }
}

enum R2UploadError: LocalizedError, Equatable {
    case incompleteConfiguration
    case invalidConfiguration
    case invalidObjectName
    case invalidObjectPrefix
    case missingSecret
    case invalidFile
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        message(localization: PluginLocalization(bundle: .main))
    }

    func message(localization: PluginLocalization) -> String {
        switch self {
        case .incompleteConfiguration:
            localization.string(
                "error.configuration.incomplete",
                defaultValue: "请先完成 R2 配置。"
            )
        case .invalidConfiguration:
            localization.string(
                "error.configuration.invalid",
                defaultValue: "R2 配置无效。"
            )
        case .invalidObjectName:
            localization.string("error.objectName.invalid", defaultValue: "文件名无效。")
        case .invalidObjectPrefix:
            localization.string(
                "error.objectPrefix.invalid",
                defaultValue: "对象路径前缀不能包含 . 或 ..。"
            )
        case .missingSecret:
            localization.string(
                "error.secret.missing",
                defaultValue: "请先保存 Secret Access Key。"
            )
        case .invalidFile:
            localization.string("error.file.invalid", defaultValue: "请选择有效的文件。")
        case .invalidResponse:
            localization.string(
                "error.response.invalid",
                defaultValue: "R2 返回了无效响应。"
            )
        case let .httpStatus(status):
            localization.format(
                "error.upload.http",
                defaultValue: "上传失败（HTTP %d）。",
                status
            )
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
