import Foundation
import Security

enum CLIArtifactVerifier {
    struct SignatureChecks {
        var check: (URL, String, String, Bool) -> OSStatus
        var assess: (URL) throws -> Int32

        static var live: Self {
            SignatureChecks(check: signatureStatus, assess: { url in
                try CLIProcess.runResult(URL(fileURLWithPath: "/usr/sbin/spctl"),
                    ["--assess", "--type", "execute", url.path], timeout: 30).status
            })
        }
    }

    static func verifySignature(at url: URL, identifier: String, team: String, notarized: Bool,
                                checks: SignatureChecks = .live) throws {
        try Task.checkCancellation()
        // Reject invalid signatures and unexpected publishers before requesting an online assessment.
        guard checks.check(url, identifier, team, false) == errSecSuccess else {
            throw CLIInstallError.signature
        }
        guard notarized else { return }
        let status = checks.check(url, identifier, team, true)
        if status == errSecSuccess { return }
        guard status == errSecCSReqFailed else { throw CLIInstallError.signature }

        try Task.checkCancellation()
        do {
            // A static `notarized` requirement can fail until Gatekeeper has fetched the ticket.
            // spctl may fetch it but reject a standalone executable as "not an app". Its exit
            // status is diagnostic only: the fresh full signature check below decides acceptance.
            let assessmentStatus = try checks.assess(url)
            AppLog.cliInstallation.info("CLI Gatekeeper assessment exited with status \(assessmentStatus)")
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            AppLog.cliInstallation.error("CLI Gatekeeper assessment could not complete")
            throw CLIInstallError.notarization
        }
        try Task.checkCancellation()
        guard checks.check(url, identifier, team, true) == errSecSuccess else {
            throw CLIInstallError.notarization
        }
    }

    private static func signatureStatus(at url: URL, identifier: String, team: String, notarized: Bool) -> OSStatus {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = CLIPeerIdentityValidator().requirementString(signingIdentifier: identifier, teamIdentifier: team)
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + (notarized ? " and notarized" : "")
        let creation = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard creation == errSecSuccess, let code else {
            AppLog.cliInstallation.error("CLI static code creation failed: \(creation)")
            return creation == errSecSuccess ? errSecParam : creation
        }
        let compilation = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        guard compilation == errSecSuccess, let requirement else {
            AppLog.cliInstallation.error("CLI signature requirement compilation failed: \(compilation)")
            return compilation == errSecSuccess ? errSecParam : compilation
        }
        // Always create a new SecStaticCode so an earlier failed evaluation is not reused.
        let status = SecStaticCodeCheckValidity(code,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement)
        if status != errSecSuccess {
            AppLog.cliInstallation.error("CLI signature verification failed: \(status), notarization required: \(notarized)")
        }
        return status
    }

    static func verifyExecutable(_ executable: URL, manifest: CLIReleaseManifest) throws {
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        // Exactly one little-endian 64-bit arm64 Mach-O slice, not a fat/universal executable.
        guard data.count > 32, Array(data.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1],
              data.count <= CLIReleaseManifest.maximumArchiveSize else { throw CLIInstallError.archive }
        try verifySignature(at: executable, identifier: manifest.signingIdentifier,
                            team: manifest.teamIdentifier, notarized: true)
        let info = CLIServiceConfiguration.executableInfoDictionary(executableURL: executable)
        guard info["CFBundleIdentifier"] as? String == manifest.signingIdentifier,
              info["CFBundleShortVersionString"] as? String == manifest.cliVersion,
              info["CFBundleVersion"] as? String == manifest.cliBuild else { throw CLIInstallError.identity }
    }

    static func validateExecution(_ executable: URL, manifest: CLIReleaseManifest, doctor: Bool) throws {
        let bytes = try CLIProcess.run(executable, [doctor ? "doctor" : "version", "--json"])
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              response["outcome"] as? String == "completed",
              let data = response["data"] as? [String: Any] else { throw CLIInstallError.validation }
        if doctor {
            guard data["hostVersion"] as? String == manifest.appVersion,
                  data["hostBuild"] as? String == manifest.appBuild,
                  let selected = response["protocolVersion"] as? Int,
                  (manifest.protocolMinimum...manifest.protocolMaximum).contains(selected) else {
                throw CLIInstallError.incompatible
            }
        } else {
            guard data["cliVersion"] as? String == manifest.cliVersion,
                  data["cliBuild"] as? String == manifest.cliBuild else { throw CLIInstallError.version }
        }
    }

    static func quarantine(_ url: URL) throws {
        let attribute = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));MacTools Nightly;\(UUID().uuidString)"
        let result = attribute.withCString { bytes in
            setxattr(url.path, "com.apple.quarantine", bytes, strlen(bytes), 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw CLIInstallError.filesystem }
    }
}

final class CLIBoundedDownload: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Redirects may use GitHub's asset CDN, but must never downgrade TLS or introduce credentials.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func fetch(_ manifest: CLIReleaseManifest, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: CLIBoundedDownload(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: manifest.assetURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength == -1 || response.expectedContentLength == manifest.size else {
            throw CLIInstallError.download
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CLIInstallError.filesystem
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        var chunk = Data()
        var count = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        for try await byte in bytes {
            guard count < manifest.size, ContinuousClock.now < deadline else { throw CLIInstallError.download }
            count += 1
            chunk.append(byte)
            if chunk.count == 65536 {
                try file.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try file.write(contentsOf: chunk)
        try file.synchronize()
        let data = try Data(contentsOf: destination)
        guard data.count == manifest.size, cliSHA256(data) == manifest.sha256 else { throw CLIInstallError.archive }
    }
}
