import Foundation
import Network

protocol IPOverviewLeakTesting: Sendable {
    func checkWebRTC(target: IPOverviewWebRTCTarget) async -> IPOverviewLeakTestResult
    func checkDNS(id: String, name: String) async -> IPOverviewLeakTestResult
}

struct IPOverviewLeakTestService: IPOverviewLeakTesting {
    private let httpClient: any IPOverviewHTTPClient
    private let timeout: TimeInterval

    init(
        httpClient: any IPOverviewHTTPClient = URLSession.shared,
        timeout: TimeInterval = 5
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    func checkWebRTC(target: IPOverviewWebRTCTarget) async -> IPOverviewLeakTestResult {
        do {
            let ip = try await STUNClient(timeout: timeout).reflexiveAddress(
                host: target.host,
                port: target.port
            )
            let geo = await geoEndpoint(ip: ip, natType: "端口限制型或对称型")
            return IPOverviewLeakTestResult(
                id: target.id,
                name: target.name,
                status: .success(geo)
            )
        } catch {
            return IPOverviewLeakTestResult(
                id: target.id,
                name: target.name,
                status: .failure(error.localizedDescription)
            )
        }
    }

    func checkDNS(id: String, name: String) async -> IPOverviewLeakTestResult {
        if let endpoint = await checkIPAPIDNSLeak() {
            return IPOverviewLeakTestResult(id: id, name: name, status: .success(endpoint))
        }

        if let endpoint = await checkSurfsharkDNSLeak() {
            return IPOverviewLeakTestResult(id: id, name: name, status: .success(endpoint))
        }

        return IPOverviewLeakTestResult(id: id, name: name, status: .failure("未获取到 DNS 出口"))
    }

    private func checkIPAPIDNSLeak() async -> IPOverviewLeakEndpoint? {
        guard let url = URL(string: "https://\(randomToken()).edns.ip-api.com/json") else {
            return nil
        }

        do {
            let (data, response) = try await fetch(url)
            guard (200..<300).contains(response.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dns = object["dns"] as? [String: Any],
                  let ip = dns["ip"] as? String
            else {
                return nil
            }

            let geo = dns["geo"] as? String
            let parts = geo?.components(separatedBy: " - ") ?? []
            return IPOverviewLeakEndpoint(
                ip: ip,
                natType: nil,
                country: parts.first,
                countryCode: nil,
                organization: parts.dropFirst().first
            )
        } catch {
            return nil
        }
    }

    private func checkSurfsharkDNSLeak() async -> IPOverviewLeakEndpoint? {
        guard let url = URL(string: "https://\(shortToken()).ipv4.surfsharkdns.com") else {
            return nil
        }

        do {
            let (data, response) = try await fetch(url)
            guard (200..<300).contains(response.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = object.values.first as? [String: Any],
                  let ip = first["IP"] as? String
            else {
                return nil
            }

            return IPOverviewLeakEndpoint(
                ip: ip,
                natType: nil,
                country: first["Country"] as? String,
                countryCode: first["CountryCode"] as? String,
                organization: first["ISP"] as? String
            )
        } catch {
            return nil
        }
    }

    private func geoEndpoint(ip: String, natType: String?) async -> IPOverviewLeakEndpoint {
        guard let url = URL(string: "https://ipwho.is/\(ip)") else {
            return IPOverviewLeakEndpoint(
                ip: ip,
                natType: natType,
                country: nil,
                countryCode: nil,
                organization: nil
            )
        }

        do {
            let (data, response) = try await fetch(url)
            guard (200..<300).contains(response.statusCode),
                  let info = IPOverviewParser.geoInfoFromIPWhois(data, ip: ip)
            else {
                return IPOverviewLeakEndpoint(
                    ip: ip,
                    natType: natType,
                    country: nil,
                    countryCode: nil,
                    organization: nil
                )
            }

            return IPOverviewLeakEndpoint(
                ip: ip,
                natType: natType,
                country: info.country,
                countryCode: info.countryCode,
                organization: info.organization ?? info.isp
            )
        } catch {
            return IPOverviewLeakEndpoint(
                ip: ip,
                natType: natType,
                country: nil,
                countryCode: nil,
                organization: nil
            )
        }
    }

    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("MacTools IP Overview", forHTTPHeaderField: "User-Agent")
        return try await httpClient.data(for: request)
    }

    private func randomToken() -> String {
        "\(Int(Date().timeIntervalSince1970))mactools\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
    }

    private func shortToken() -> String {
        "mt\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
    }
}

struct STUNClient {
    enum Error: LocalizedError {
        case invalidPort
        case timedOut
        case noMappedAddress
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                return "STUN 端口无效"
            case .timedOut:
                return "STUN 请求超时"
            case .noMappedAddress:
                return "未返回外部地址"
            case .failed(let message):
                return message
            }
        }
    }

    let timeout: TimeInterval

    func reflexiveAddress(host: String, port: UInt16) async throws -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Error.invalidPort
        }

        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .udp
            )
            let transactionID = Self.transactionID()
            let request = Self.bindingRequest(transactionID: transactionID)
            let resumeState = STUNResumeState(connection: connection, continuation: continuation)

            @Sendable func finish(_ result: Result<String, Swift.Error>) {
                resumeState.finish(result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(Error.failed(error.localizedDescription)))
                            return
                        }

                        connection.receiveMessage { data, _, _, error in
                            if let error {
                                finish(.failure(Error.failed(error.localizedDescription)))
                                return
                            }
                            guard let data,
                                  let ip = Self.parseMappedAddress(data, transactionID: transactionID)
                            else {
                                finish(.failure(Error.noMappedAddress))
                                return
                            }
                            finish(.success(ip))
                        }
                    })
                case .failed(let error):
                    finish(.failure(Error.failed(error.localizedDescription)))
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(.failure(Error.timedOut))
            }
        }
    }

    private static func transactionID() -> [UInt8] {
        (0..<12).map { _ in UInt8.random(in: 0...255) }
    }

    private static func bindingRequest(transactionID: [UInt8]) -> Data {
        var bytes: [UInt8] = [
            0x00, 0x01,
            0x00, 0x00,
            0x21, 0x12, 0xA4, 0x42
        ]
        bytes.append(contentsOf: transactionID)
        return Data(bytes)
    }

    static func parseMappedAddress(_ data: Data, transactionID: [UInt8]) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20,
              bytes[0] == 0x01,
              bytes[1] == 0x01,
              Array(bytes[8..<20]) == transactionID
        else {
            return nil
        }

        var index = 20
        while index + 4 <= bytes.count {
            let type = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            let length = Int(UInt16(bytes[index + 2]) << 8 | UInt16(bytes[index + 3]))
            let valueStart = index + 4
            let valueEnd = valueStart + length
            guard valueEnd <= bytes.count else { return nil }

            if type == 0x0020 || type == 0x0001 {
                let value = Array(bytes[valueStart..<valueEnd])
                if let address = mappedAddress(value, isXOR: type == 0x0020, transactionID: transactionID) {
                    return address
                }
            }

            index = valueEnd + ((4 - (length % 4)) % 4)
        }

        return nil
    }

    private static func mappedAddress(_ value: [UInt8], isXOR: Bool, transactionID: [UInt8]) -> String? {
        guard value.count >= 8 else { return nil }
        let family = value[1]
        if family == 0x01 {
            var address = Array(value[4..<8])
            if isXOR {
                let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
                for index in 0..<4 {
                    address[index] ^= cookie[index]
                }
            }
            return address.map(String.init).joined(separator: ".")
        }

        if family == 0x02, value.count >= 20 {
            var address = Array(value[4..<20])
            if isXOR {
                // RFC 5389: XOR-MAPPED-ADDRESS for IPv6 XORs all 16 bytes with
                // the magic cookie concatenated with the 96-bit transaction ID.
                let mask: [UInt8] = [0x21, 0x12, 0xA4, 0x42] + transactionID
                for index in 0..<min(address.count, mask.count) {
                    address[index] ^= mask[index]
                }
            }
            var chunks: [String] = []
            for index in stride(from: 0, to: address.count, by: 2) {
                let chunk = UInt16(address[index]) << 8 | UInt16(address[index + 1])
                chunks.append(String(chunk, radix: 16))
            }
            return chunks.joined(separator: ":")
        }

        return nil
    }
}

private final class STUNResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<String, Swift.Error>

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<String, Swift.Error>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Swift.Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        connection.cancel()
        continuation.resume(with: result)
    }
}
