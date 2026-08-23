import CoreFoundation
import Foundation

enum AppInstanceLaunchDisposition: Equatable {
    case primary(recoveryRequested: Bool)
    case secondary(AppInstanceForwardingResult)
}

enum AppInstanceForwardingResult: Equatable {
    case acknowledged
    case timedOut
    case rejected
}

enum AppInstanceForwardingOutcome: Equatable {
    case acknowledged
    case timedOut
    case rejected
    case becamePrimary
}

enum AppInstanceResponse: String, Codable, Equatable {
    case accepted
    case notReady
    case unsupported
    case invalid
}

struct AppInstanceCommand: Codable, Equatable {
    let version: Int
    let command: String
    let urlStrings: [String]
    let requestID: UUID

    static let currentVersion = 1
    static let probe = "probe"
    static let showSettings = "show-settings"
    static let openURLs = "open-urls"
    static let maximumPayloadSize = 16 * 1_024 * 1_024

    private enum CodingKeys: String, CodingKey {
        case version
        case command
        case urlStrings
        case requestID
    }

    init(
        version: Int,
        command: String,
        urlStrings: [String] = [],
        requestID: UUID
    ) {
        self.version = version
        self.command = command
        self.urlStrings = urlStrings
        self.requestID = requestID
    }

    static func showSettingsRequest() -> Self {
        Self(
            version: currentVersion,
            command: showSettings,
            urlStrings: [],
            requestID: UUID()
        )
    }

    static func probeRequest() -> Self {
        Self(
            version: currentVersion,
            command: probe,
            urlStrings: [],
            requestID: UUID()
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        command = try container.decode(String.self, forKey: .command)
        urlStrings = try container.decodeIfPresent([String].self, forKey: .urlStrings) ?? []
        requestID = try container.decode(UUID.self, forKey: .requestID)
    }

    static func openURLsRequest(_ urls: [URL]) -> Self {
        Self(
            version: currentVersion,
            command: openURLs,
            urlStrings: urls.map(\.absoluteString),
            requestID: UUID()
        )
    }

    var fitsPayloadSizeLimit: Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return data.count <= Self.maximumPayloadSize
    }

    var isSupported: Bool {
        guard version == Self.currentVersion else { return false }

        switch command {
        case Self.probe:
            return urlStrings.isEmpty
        case Self.showSettings:
            return urlStrings.isEmpty
        case Self.openURLs:
            return !urlStrings.isEmpty && urlStrings.allSatisfy { URL(string: $0) != nil }
        default:
            return false
        }
    }
}

actor AppInstanceCoordinator {
    fileprivate static let messageID: Int32 = 1
    private static let sendTimeout: CFTimeInterval = 0.5
    private static let receiveTimeout: CFTimeInterval = 0.5
    private static let forwardingTimeout: TimeInterval = 1.5
    private static let urlForwardingReserve: TimeInterval = 0.5
    private static let retryDelay: TimeInterval = 0.1

    private let portName: String
    private let callbackBox: CallbackBox
    private let transport: any AppInstanceTransport

    nonisolated static func makeForwardingDeadline() -> Date {
        Date().addingTimeInterval(forwardingTimeout)
    }

    nonisolated static func makeSettingsRecoveryDeadline(
        forwardingDeadline: Date
    ) -> Date {
        forwardingDeadline.addingTimeInterval(-urlForwardingReserve)
    }

    init(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        transport: any AppInstanceTransport = CFMessagePortInstanceTransport()
    ) {
        let identifier = bundleIdentifier ?? "com.example.mactools"
        portName = "\(identifier).instance-coordination.v1"
        callbackBox = CallbackBox()
        self.transport = transport
    }

    func setCommandHandler(_ handler: @escaping @Sendable (AppInstanceCommand) -> AppInstanceResponse) {
        callbackBox.setHandler(handler)
    }

    func claimPrimaryPortIfPossible() -> Bool {
        if registerLocalPortIfPossible() {
            AppLog.instanceCoordination.debug("Elected primary instance")
            return true
        }

        return false
    }

    func resolveSecondaryLaunch(
        requestSettings: Bool = false,
        deadline: Date = AppInstanceCoordinator.makeForwardingDeadline()
    ) async -> AppInstanceLaunchDisposition {
        let command = requestSettings
            ? AppInstanceCommand.showSettingsRequest()
            : AppInstanceCommand.probeRequest()
        let operation = requestSettings ? "settings recovery" : "instance probe"
        let result = await forward(command, operation: operation, deadline: deadline)

        switch result {
        case .acknowledged:
            return .secondary(.acknowledged)
        case .timedOut:
            return .secondary(.timedOut)
        case .rejected:
            return .secondary(.rejected)
        case .becamePrimary:
            return .primary(recoveryRequested: requestSettings)
        }
    }

    func forwardURLs(
        _ urls: [URL],
        deadline: Date = AppInstanceCoordinator.makeForwardingDeadline()
    ) async -> AppInstanceForwardingOutcome {
        guard !urls.isEmpty else { return .acknowledged }
        return await forward(
            AppInstanceCommand.openURLsRequest(urls),
            operation: "deep links",
            deadline: deadline
        )
    }

    private func forward(
        _ command: AppInstanceCommand,
        operation: String,
        deadline: Date
    ) async -> AppInstanceForwardingOutcome {
        while Date() < deadline {
            guard !Task.isCancelled else {
                AppLog.instanceCoordination.debug("Cancelled \(operation, privacy: .public) forwarding")
                return .timedOut
            }

            switch forwardRequest(command, deadline: deadline) {
            case .accepted:
                AppLog.instanceCoordination.debug("Forwarded \(operation, privacy: .public)")
                return .acknowledged
            case .notReady, .timedOut:
                break
            case .invalidPort:
                if registerLocalPortIfPossible() {
                    AppLog.instanceCoordination.notice("Recovered primary ownership after an invalid port")
                    return .becamePrimary
                }
                break
            case .rejected:
                AppLog.instanceCoordination.error("\(operation, privacy: .public) forwarding was rejected")
                return .rejected
            }

            guard !Task.isCancelled else {
                AppLog.instanceCoordination.debug("Cancelled \(operation, privacy: .public) forwarding")
                return .timedOut
            }
            let retryDelay = min(Self.retryDelay, max(0, deadline.timeIntervalSinceNow))
            try? await Task.sleep(for: .seconds(retryDelay))
        }

        AppLog.instanceCoordination.error("Timed out forwarding \(operation, privacy: .public)")
        return .timedOut
    }

    func invalidate() {
        transport.invalidate()
        AppLog.instanceCoordination.debug("Invalidated primary instance port")
    }

    private func registerLocalPortIfPossible() -> Bool {
        transport.registerLocalPort(name: portName, callbackBox: callbackBox)
    }

    private func forwardRequest(
        _ command: AppInstanceCommand,
        deadline: Date
    ) -> ForwardingAttempt {
        guard let data = try? JSONEncoder().encode(command) else {
            return .rejected
        }
        guard data.count <= AppInstanceCommand.maximumPayloadSize else {
            AppLog.instanceCoordination.warning("Rejected oversized outgoing instance coordination message")
            return .rejected
        }

        let remainingTime = deadline.timeIntervalSinceNow
        guard remainingTime > 0 else { return .timedOut }
        let sendTimeout = min(Self.sendTimeout, remainingTime / 2)
        let receiveTimeout = min(Self.receiveTimeout, remainingTime - sendTimeout)

        let responseData: Data
        switch transport.send(
            name: portName,
            messageID: Self.messageID,
            data: data,
            sendTimeout: sendTimeout,
            receiveTimeout: receiveTimeout
        ) {
        case let .response(data): responseData = data
        case .timedOut: return .timedOut
        case .invalidPort: return .invalidPort
        case .rejected: return .rejected
        }
        guard let response = try? JSONDecoder().decode(AppInstanceResponse.self, from: responseData) else {
            return .rejected
        }

        switch response {
        case .accepted:
            return .accepted
        case .notReady:
            return .notReady
        case .unsupported, .invalid:
            return .rejected
        }
    }

}

protocol AppInstanceTransport: AnyObject {
    func registerLocalPort(name: String, callbackBox: CallbackBox) -> Bool
    func send(
        name: String,
        messageID: Int32,
        data: Data,
        sendTimeout: CFTimeInterval,
        receiveTimeout: CFTimeInterval
    ) -> AppInstanceTransportResult
    func invalidate()
}

enum AppInstanceTransportResult {
    case response(Data)
    case timedOut
    case invalidPort
    case rejected
}

final class CFMessagePortInstanceTransport: AppInstanceTransport {
    private var localPort: CFMessagePort?

    func registerLocalPort(name: String, callbackBox: CallbackBox) -> Bool {
        guard localPort == nil else { return true }
        var shouldFreeInfo = DarwinBoolean(false)
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard let port = CFMessagePortCreateLocal(
            kCFAllocatorDefault, name as CFString, Self.receiveMessage,
            &context, &shouldFreeInfo
        ) else { return false }
        guard !shouldFreeInfo.boolValue else { return false }
        CFMessagePortSetDispatchQueue(port, DispatchQueue.main)
        localPort = port
        return true
    }

    func send(
        name: String,
        messageID: Int32,
        data: Data,
        sendTimeout: CFTimeInterval,
        receiveTimeout: CFTimeInterval
    ) -> AppInstanceTransportResult {
        guard let remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, name as CFString) else {
            return .invalidPort
        }
        var returnedData: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(
            remotePort, messageID, data as CFData, sendTimeout, receiveTimeout,
            CFRunLoopMode.defaultMode.rawValue, &returnedData
        )
        if result == kCFMessagePortReceiveTimeout || result == kCFMessagePortSendTimeout {
            return .timedOut
        }
        guard result == kCFMessagePortSuccess else { return .invalidPort }
        guard let returnedData else { return .rejected }
        return .response(returnedData.takeRetainedValue() as Data)
    }

    func invalidate() {
        guard let localPort else { return }
        CFMessagePortInvalidate(localPort)
        self.localPort = nil
    }

    private static let receiveMessage: CFMessagePortCallBack = { _, messageID, data, info in
        guard messageID == AppInstanceCoordinator.messageID, let data, let info else {
            return encodedResponse(.invalid)
        }
        let callbackBox = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        return encodedResponse(callbackBox.response(for: data as Data))
    }

    private static func encodedResponse(_ response: AppInstanceResponse) -> Unmanaged<CFData>? {
        guard let data = try? JSONEncoder().encode(response) else { return nil }
        return Unmanaged.passRetained(data as CFData)
    }
}

private enum ForwardingAttempt {
    case accepted
    case notReady
    case invalidPort
    case rejected
    case timedOut
}

final class CallbackBox {
    private static let acceptedRequestLifetime: TimeInterval = 30

    private let lock = NSLock()
    private var handler: (@Sendable (AppInstanceCommand) -> AppInstanceResponse)?
    private var acceptedRequestDates = [UUID: Date]()

    func setHandler(_ handler: @escaping @Sendable (AppInstanceCommand) -> AppInstanceResponse) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func response(for data: Data) -> AppInstanceResponse {
        guard data.count <= AppInstanceCommand.maximumPayloadSize else {
            AppLog.instanceCoordination.warning("Rejected oversized instance coordination message")
            return .invalid
        }
        guard let command = try? JSONDecoder().decode(AppInstanceCommand.self, from: data) else {
            AppLog.instanceCoordination.warning("Rejected malformed instance coordination message")
            return .invalid
        }

        guard command.isSupported else {
            AppLog.instanceCoordination.warning("Rejected unsupported instance coordination command")
            return .unsupported
        }

        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        acceptedRequestDates = acceptedRequestDates.filter {
            now.timeIntervalSince($0.value) < Self.acceptedRequestLifetime
        }

        if acceptedRequestDates[command.requestID] != nil {
            AppLog.instanceCoordination.debug("Repeated instance coordination command accepted")
            return .accepted
        }

        AppLog.instanceCoordination.debug("Received instance coordination command")
        let response = handler?(command) ?? .notReady
        if response == .accepted {
            acceptedRequestDates[command.requestID] = now
        }
        AppLog.instanceCoordination.debug("Instance coordination response: \(response.rawValue, privacy: .public)")
        return response
    }
}
