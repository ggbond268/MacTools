import Foundation
import XCTest

@testable import CloudflareR2Plugin

final class R2UploadServiceTests: XCTestCase {

    func testUploadBuildsSignedPutWithUnsignedPayloadAndProgress() async throws {
        let fileURL = try makeFile("report(1).pdf", Data("hello".utf8))
        defer { removeParent(of: fileURL) }
        let client = R2HTTPClientMock(statusCode: 200, progressValues: [0.25, 0.75, 1])
        let recorder = ProgressRecorder()
        let service = R2UploadService(
            httpClient: client, now: { Date(timeIntervalSince1970: 1_440_937_800) })
        let result = try await service.upload(
            fileURL: fileURL,
            configuration: configuration(
                publicBaseURL: "https://files.example.com", objectPrefix: "uploads"),
            secretAccessKey: "secret"
        ) { recorder.append($0) }
        XCTAssertEqual(result.objectKey, "uploads/report(1).pdf")
        XCTAssertEqual(result.url?.absoluteString, "https://files.example.com/uploads/report(1).pdf")
        let request = try XCTUnwrap(client.recordedRequest)
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
            "/bucket/uploads/report%281%29.pdf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Content-Sha256"), "UNSIGNED-PAYLOAD")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertEqual(recorder.values, [0.25, 0.75, 1])
    }

    func testExplicitObjectNameRejectsPathSeparators() async throws {
        let fileURL = try makeFile("original.pdf", Data())
        defer { removeParent(of: fileURL) }
        let client = R2HTTPClientMock(statusCode: 200)
        await assertError(.invalidObjectName) {
            try await R2UploadService(httpClient: client).upload(
                fileURL: fileURL,
                objectName: "folder/renamed.pdf",
                configuration: self.configuration(),
                secretAccessKey: "secret"
            )
        }
        XCTAssertNil(client.recordedRequest)
    }

    func testObjectExistsUsesSignedHeadRequest() async throws {
        let checker = R2HTTPObjectCheckerMock(statusCodes: [200])
        let service = R2UploadService(
            httpClient: R2HTTPClientMock(statusCode: 200),
            objectCheckClient: checker,
            now: { Date(timeIntervalSince1970: 1_440_937_800) }
        )
        let exists = try await service.objectExists(
            objectName: "a+b.txt",
            configuration: configuration(objectPrefix: "uploads"),
            secretAccessKey: "secret"
        )
        XCTAssertTrue(exists)
        let request = try XCTUnwrap(checker.recordedRequests.first)
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
            "/bucket/uploads/a%2Bb.txt"
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testObjectExistsTreats404AsMissing() async throws {
        let checker = R2HTTPObjectCheckerMock(statusCodes: [404])
        let exists = try await R2UploadService(
            objectCheckClient: checker
        ).objectExists(
            objectName: "file.txt",
            configuration: configuration(),
            secretAccessKey: "secret"
        )
        XCTAssertFalse(exists)
    }

    func testUploadRejectsRelativeObjectPrefixSegmentsBeforeNetwork() async throws {
        let fileURL = try makeFile("file.txt", Data())
        defer { removeParent(of: fileURL) }
        for prefix in [".", "..", "uploads/../private", "uploads/./today"] {
            let client = R2HTTPClientMock(statusCode: 200)
            await assertError(.invalidObjectPrefix) {
                try await R2UploadService(httpClient: client).upload(
                    fileURL: fileURL,
                    configuration: self.configuration(objectPrefix: prefix),
                    secretAccessKey: "secret"
                )
            }
            XCTAssertNil(client.recordedRequest, prefix)
        }
    }

    func testUploadRejectsIncompleteConfigurationBeforeNetwork() async {
        let client = R2HTTPClientMock(statusCode: 200)
        await assertError(.incompleteConfiguration) {
            try await R2UploadService(httpClient: client).upload(
                fileURL: URL(fileURLWithPath: "/tmp/file"),
                configuration: self.configuration(accountID: ""), secretAccessKey: "secret")
        }
        XCTAssertNil(client.recordedRequest)
    }

    func testUploadRejectsNonFileAndDirectory() async throws {
        let service = R2UploadService(httpClient: R2HTTPClientMock(statusCode: 200))
        await assertError(.invalidFile) {
            try await service.upload(
                fileURL: URL(string: "https://example.com/file")!, configuration: self.configuration(),
                secretAccessKey: "secret")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await assertError(.invalidFile) {
            try await service.upload(
                fileURL: directory, configuration: self.configuration(), secretAccessKey: "secret")
        }
    }

    func testUploadMapsHTTPAndNonHTTPFailures() async throws {
        let fileURL = try makeFile("file.txt", Data())
        defer { removeParent(of: fileURL) }
        await assertError(.httpStatus(403)) {
            try await R2UploadService(httpClient: R2HTTPClientMock(statusCode: 403)).upload(
                fileURL: fileURL, configuration: self.configuration(), secretAccessKey: "secret")
        }
        let nonHTTP = R2HTTPClientMock(responseFactory: {
            URLResponse(url: $0.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        })
        await assertError(.invalidResponse) {
            try await R2UploadService(httpClient: nonHTTP).upload(
                fileURL: fileURL, configuration: self.configuration(), secretAccessKey: "secret")
        }
    }

    func testSignerIncludesStrictCanonicalURI() throws {
        let canonical = "/bucket/a%2Bb.txt"
        var request = URLRequest(
            url: R2S3URIEncoder.requestURL(accountID: "example", canonicalURI: canonical)!)
        request.httpMethod = "PUT"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        try R2RequestSigner.sign(
            request: &request, canonicalURI: canonical, payloadHash: "UNSIGNED-PAYLOAD",
            accessKeyID: "ACCESS", secretAccessKey: "SECRET",
            date: Date(timeIntervalSince1970: 1_440_937_800))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Date"), "20150830T123000Z")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Authorization")?.contains(
                "Credential=ACCESS/20150830/auto/s3/aws4_request") == true)
    }

    func testPreCancelledURLSessionOperationNeverResumesUploadTask() async throws {
        let fileURL = try makeFile("file.txt", Data("body".utf8))
        defer { removeParent(of: fileURL) }
        let resumeRecorder = InvocationRecorder()
        let operation = R2URLSessionUploadOperation(
            progress: { _ in },
            onTaskResume: { resumeRecorder.record() }
        )
        operation.cancel()
        var request = URLRequest(url: URL(string: "https://example.invalid/upload")!)
        request.httpMethod = "PUT"

        do {
            _ = try await operation.start(request: request, fileURL: fileURL)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertEqual(resumeRecorder.count, 0)
    }

    private func configuration(
        accountID: String = "account", publicBaseURL: String = "", objectPrefix: String = ""
    ) -> R2Configuration {
        R2Configuration(
            accountID: accountID, bucket: "bucket", accessKeyID: "access", publicBaseURL: publicBaseURL,
            objectPrefix: objectPrefix)
    }
    private func makeFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    private func removeParent(of url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    private func assertError(_ expected: R2UploadError, operation: () async throws -> R2UploadResult)
        async
    {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch { XCTAssertEqual(error as? R2UploadError, expected) }
    }
}

final class R2HTTPClientMock: R2HTTPUploading, @unchecked Sendable {
    private let lock = NSLock()
    private let responseFactory: @Sendable (URLRequest) -> URLResponse
    private let progressValues: [Double]
    private var storedRequest: URLRequest?
    convenience init(statusCode: Int, progressValues: [Double] = []) {
        self.init(
            progressValues: progressValues,
            responseFactory: {
                HTTPURLResponse(url: $0.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            })
    }
    init(
        progressValues: [Double] = [], responseFactory: @escaping @Sendable (URLRequest) -> URLResponse
    ) {
        self.progressValues = progressValues
        self.responseFactory = responseFactory
    }
    var recordedRequest: URLRequest? { lock.withLock { storedRequest } }
    func upload(
        for request: URLRequest, fromFile fileURL: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        lock.withLock { storedRequest = request }
        progressValues.forEach(progress)
        return (Data(), responseFactory(request))
    }
}

final class R2HTTPObjectCheckerMock: R2HTTPObjectChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var statusCodes: [Int]
    private var storedRequests: [URLRequest] = []

    init(statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    var recordedRequests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let statusCode = lock.withLock { () -> Int in
            storedRequests.append(request)
            return statusCodes.isEmpty ? 404 : statusCodes.removeFirst()
        }
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
}

final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    var count: Int { lock.withLock { storedCount } }
    func record() { lock.withLock { storedCount += 1 } }
}
