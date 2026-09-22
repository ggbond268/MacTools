import XCTest
import MacToolsPluginKit
@testable import IPOverviewPlugin

@MainActor
final class IPOverviewPluginTests: XCTestCase {

    func testCanonicalCopyActionsRefreshBeforeCopyingCurrentAddresses() async throws {
        let pasteboard = NSPasteboard(name: .init("IPOverviewPluginTests.\(UUID().uuidString)"))
        let snapshot = IPOverviewSnapshot(
            publicIPv4: IPOverviewPublicIPResult(
                family: .ipv4,
                ip: "203.0.113.8",
                source: "Test"
            ),
            publicIPv6: nil,
            localAddresses: [
                IPOverviewLocalAddress(
                    id: "en0-192.168.1.10",
                    interfaceName: "en0",
                    address: "192.168.1.10",
                    family: .ipv4
                ),
            ],
            geoInfoByIP: [:],
            sourceResults: [],
            lastUpdated: Date(),
            errorMessage: nil,
            isRefreshing: false
        )
        let provider = IPOverviewProviderSpy(publicSnapshot: snapshot)
        let viewModel = IPOverviewViewModel(
            provider: provider,
            storage: IPOverviewPluginTestStorage(),
            pasteboard: pasteboard
        )
        let plugin = IPOverviewPlugin(viewModel: viewModel)

        XCTAssertEqual(plugin.actionCatalogEntries.count, 2)
        for (reference, expected) in zip(
            plugin.actionCatalogEntries.map(\.reference),
            ["192.168.1.10", "203.0.113.8"]
        ) {
            let result = try await plugin.beginAction(
                ActionInvocation(reference: reference, source: .test, mode: .background)
            ).result()
            XCTAssertEqual(result, .succeeded())
            XCTAssertEqual(pasteboard.string(forType: .string), expected)
        }
        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 2)
    }

    func testCopyPublicIPFailsInsteadOfUsingCachedAddressWhenRefreshFails() async throws {
        let pasteboard = NSPasteboard(name: .init("IPOverviewPluginTests.\(UUID().uuidString)"))
        let provider = IPOverviewProviderSpy(
            publicSnapshots: [
                testSnapshot(ip: "203.0.113.8", lastUpdated: Date()),
                .empty,
            ]
        )
        let viewModel = IPOverviewViewModel(
            provider: provider,
            storage: IPOverviewPluginTestStorage(),
            pasteboard: pasteboard
        )
        let initialRefresh = try XCTUnwrap(viewModel.refreshAddresses())
        await initialRefresh.value
        let plugin = IPOverviewPlugin(viewModel: viewModel)
        let publicReference = try XCTUnwrap(
            plugin.actionCatalogEntries.map(\.reference).first {
                $0.key.actionID == "copy-public-ipv4"
            }
        )

        let result = try await plugin.beginAction(
            ActionInvocation(reference: publicReference, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected the action to fail without a current public IP")
        }
        XCTAssertNil(pasteboard.string(forType: .string))
        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 2)
    }

    func testCopyLocalIPFailsInsteadOfUsingAnAddressMissingAfterRefresh() async throws {
        let pasteboard = NSPasteboard(name: .init("IPOverviewPluginTests.\(UUID().uuidString)"))
        let provider = IPOverviewProviderSpy(
            publicSnapshots: [
                testSnapshot(ip: "203.0.113.8", lastUpdated: Date()),
                .empty,
            ]
        )
        let viewModel = IPOverviewViewModel(
            provider: provider,
            storage: IPOverviewPluginTestStorage(),
            pasteboard: pasteboard
        )
        let initialRefresh = try XCTUnwrap(viewModel.refreshAddresses())
        await initialRefresh.value
        let plugin = IPOverviewPlugin(viewModel: viewModel)
        let localReference = try XCTUnwrap(
            plugin.actionCatalogEntries.map(\.reference).first {
                $0.key.actionID == "copy-local-ipv4"
            }
        )

        let result = try await plugin.beginAction(
            ActionInvocation(reference: localReference, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected the action to fail without a current local IPv4 address")
        }
        XCTAssertNil(pasteboard.string(forType: .string))
        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 2)
    }

    func testRefreshIfNeededOnlyCollectsAddresses() async throws {
        let provider = IPOverviewProviderSpy(
            publicSnapshot: IPOverviewSnapshot(
                publicIPv4: IPOverviewPublicIPResult(
                    family: .ipv4,
                    ip: "203.0.113.8",
                    source: "Test"
                ),
                publicIPv6: nil,
                localAddresses: [],
                geoInfoByIP: [:],
                sourceResults: [],
                lastUpdated: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        )
        let viewModel = IPOverviewViewModel(
            provider: provider,
            storage: IPOverviewPluginTestStorage()
        )

        let refreshTask = try XCTUnwrap(viewModel.refreshIfNeeded())
        await refreshTask.value

        XCTAssertEqual(viewModel.snapshot.publicIPv4?.ip, "203.0.113.8")
        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 1)
        XCTAssertEqual(callCounts.full, 0)
    }

    func testMeasureNetworkQualityUpdatesState() async throws {
        let measurement = IPOverviewNetworkQualityMeasurement(
            baseRTTMilliseconds: 50,
            downloadThroughputBitsPerSecond: 100_000_000,
            uploadThroughputBitsPerSecond: 20_000_000,
            downloadResponsivenessRPM: 80,
            uploadResponsivenessRPM: 90,
            downloadPhaseDuration: 3,
            uploadPhaseDuration: 4,
            interfaceName: "en0",
            testEndpoint: "example.apple.com",
            startDate: nil,
            endDate: nil
        )
        let viewModel = IPOverviewViewModel(
            provider: IPOverviewProviderSpy(publicSnapshot: .empty),
            networkQualityMeasurer: IPOverviewNetworkQualityMeasurerSpy(result: .success(measurement)),
            storage: IPOverviewPluginTestStorage()
        )

        viewModel.measureNetworkQuality()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.networkQualityState.measurement, measurement)
        XCTAssertFalse(viewModel.isMeasuringNetworkQuality)
    }

    func testWebRTCWarnsWhenStunEndpointDiffersFromPublicIP() {
        let snapshot = leakAssessmentSnapshot(publicIPv4: "203.0.113.8", country: "United States", countryCode: "US")
        let assessment = IPOverviewLeakAssessment.evaluate(
            kind: .webRTC,
            results: [
                leakResult(
                    id: "google",
                    ip: "198.51.100.24",
                    country: "Japan",
                    countryCode: "JP"
                )
            ],
            snapshot: snapshot,
            isRunning: false
        )

        XCTAssertEqual(assessment.state, .warning)
        XCTAssertEqual(assessment.reason, .webRTCDifferentIP)
        XCTAssertEqual(assessment.issueEndpoint?.ip, "198.51.100.24")
    }

    func testWebRTCClearsWhenStunEndpointMatchesPublicIP() {
        let snapshot = leakAssessmentSnapshot(publicIPv4: "203.0.113.8", country: "United States", countryCode: "US")
        let assessment = IPOverviewLeakAssessment.evaluate(
            kind: .webRTC,
            results: [
                leakResult(
                    id: "google",
                    ip: "203.0.113.8",
                    country: "United States",
                    countryCode: "US"
                )
            ],
            snapshot: snapshot,
            isRunning: false
        )

        XCTAssertEqual(assessment.state, .clear)
        XCTAssertEqual(assessment.reason, .webRTCMatchesPublicIP)
    }

    func testDNSWarnsWhenResolverRegionDiffersFromPublicRegion() {
        let assessment = IPOverviewLeakAssessment.evaluate(
            kind: .dns,
            results: [
                leakResult(
                    id: "dns-1",
                    ip: "198.51.100.24",
                    country: "Japan",
                    countryCode: "JP"
                )
            ],
            snapshot: leakAssessmentSnapshot(publicIPv4: "203.0.113.8", country: "United States", countryCode: "US"),
            isRunning: false
        )

        XCTAssertEqual(assessment.state, .warning)
        XCTAssertEqual(assessment.reason, .dnsDifferentEgressRegion)
        XCTAssertEqual(assessment.issueEndpoint?.countryCode, "JP")
    }
}

private func leakResult(
    id: String,
    ip: String,
    country: String?,
    countryCode: String?
) -> IPOverviewLeakTestResult {
    IPOverviewLeakTestResult(
        id: id,
        name: id,
        status: .success(IPOverviewLeakEndpoint(
            ip: ip,
            natType: nil,
            country: country,
            countryCode: countryCode,
            organization: "Example Network"
        ))
    )
}

private func leakAssessmentSnapshot(
    publicIPv4: String,
    country: String?,
    countryCode: String?
) -> IPOverviewSnapshot {
    IPOverviewSnapshot(
        publicIPv4: IPOverviewPublicIPResult(family: .ipv4, ip: publicIPv4, source: "Test"),
        publicIPv6: nil,
        localAddresses: [],
        geoInfoByIP: [
            publicIPv4: IPOverviewGeoInfo(
                ip: publicIPv4,
                country: country,
                countryCode: countryCode,
                region: nil,
                city: nil,
                isp: "Example ISP",
                organization: "Example ISP",
                asn: "AS64500",
                timezone: nil,
                networkType: .residential,
                isProxy: nil,
                isHosting: nil,
                source: "Test"
            )
        ],
        sourceResults: [],
        lastUpdated: Date(),
        errorMessage: nil,
        isRefreshing: false
    )
}

private func testSnapshot(ip: String, lastUpdated: Date) -> IPOverviewSnapshot {
    IPOverviewSnapshot(
        publicIPv4: IPOverviewPublicIPResult(family: .ipv4, ip: ip, source: "Test"),
        publicIPv6: nil,
        localAddresses: [
            IPOverviewLocalAddress(
                id: "en0-192.168.1.10",
                interfaceName: "en0",
                address: "192.168.1.10",
                family: .ipv4
            )
        ],
        geoInfoByIP: [
            ip: IPOverviewGeoInfo(
                ip: ip,
                country: "United States",
                countryCode: "US",
                region: "California",
                city: "Los Angeles",
                isp: "Example ISP",
                organization: "Example ISP",
                asn: "AS64500",
                timezone: "America/Los_Angeles",
                networkType: .residential,
                isProxy: false,
                isHosting: false,
                source: "Test"
            )
        ],
        sourceResults: [
            IPOverviewSourceResult(
                id: "test-source",
                family: .ipv4,
                route: .international,
                source: "Test IPv4",
                status: .success(ip)
            )
        ],
        lastUpdated: lastUpdated,
        errorMessage: nil,
        isRefreshing: false
    )
}

private actor IPOverviewProviderSpy: IPOverviewProviding {
    private(set) var collectSnapshotCallCount = 0
    private(set) var collectAddressSnapshotCallCount = 0
    private let publicSnapshots: [IPOverviewSnapshot]
    private let fullSnapshot: IPOverviewSnapshot
    private let blockedAddressCallNumber: Int?
    private let blockedAddressCallRelease = IPOverviewAddressRefreshGate()

    init(publicSnapshot: IPOverviewSnapshot, fullSnapshot: IPOverviewSnapshot = .empty) {
        self.publicSnapshots = [publicSnapshot]
        self.fullSnapshot = fullSnapshot
        self.blockedAddressCallNumber = nil
    }

    init(
        publicSnapshots: [IPOverviewSnapshot],
        fullSnapshot: IPOverviewSnapshot = .empty,
        blockedAddressCallNumber: Int? = nil
    ) {
        precondition(!publicSnapshots.isEmpty)
        self.publicSnapshots = publicSnapshots
        self.fullSnapshot = fullSnapshot
        self.blockedAddressCallNumber = blockedAddressCallNumber
    }

    func collectSnapshot() async -> IPOverviewSnapshot {
        collectSnapshotCallCount += 1
        return fullSnapshot
    }

    func collectAddressSnapshot(preserving snapshot: IPOverviewSnapshot) async -> IPOverviewSnapshot {
        collectAddressSnapshotCallCount += 1
        if collectAddressSnapshotCallCount == blockedAddressCallNumber {
            await blockedAddressCallRelease.wait()
        }
        let index = min(collectAddressSnapshotCallCount - 1, publicSnapshots.count - 1)
        return publicSnapshots[index]
    }

    func releaseBlockedAddressCall() async {
        await blockedAddressCallRelease.open()
    }

    func callCounts() -> (full: Int, addresses: Int) {
        (collectSnapshotCallCount, collectAddressSnapshotCallCount)
    }
}

private actor IPOverviewAddressRefreshGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waitingContinuations = continuations
        continuations.removeAll()
        for continuation in waitingContinuations {
            continuation.resume()
        }
    }
}

private struct IPOverviewNetworkQualityMeasurerSpy: IPOverviewNetworkQualityMeasuring {
    let result: IPOverviewNetworkQualityMeasurementResult
    var events: [IPOverviewNetworkQualityProgressEvent] = []

    func measure(
        onProgress: @escaping @Sendable (IPOverviewNetworkQualityProgressEvent) async -> Void
    ) async -> IPOverviewNetworkQualityMeasurementResult {
        for event in events {
            await onProgress(event)
        }
        return result
    }
}

@MainActor
private final class IPOverviewPluginTestStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
