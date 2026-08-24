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

    func testCopyPublicIPPrefersRefreshedAddressOverCachedSnapshot() async throws {
        let pasteboard = NSPasteboard(name: .init("IPOverviewPluginTests.\(UUID().uuidString)"))
        let provider = IPOverviewProviderSpy(
            publicSnapshots: [
                testSnapshot(ip: "203.0.113.8", lastUpdated: Date()),
                testSnapshot(ip: "198.51.100.24", lastUpdated: Date()),
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

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(pasteboard.string(forType: .string), "198.51.100.24")
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

    func testCopyPublicIPWaitsForAnInFlightRefresh() async throws {
        let pasteboard = NSPasteboard(name: .init("IPOverviewPluginTests.\(UUID().uuidString)"))
        let provider = IPOverviewProviderSpy(
            publicSnapshots: [
                testSnapshot(ip: "203.0.113.8", lastUpdated: Date()),
                testSnapshot(ip: "198.51.100.24", lastUpdated: Date()),
            ],
            blockedAddressCallNumber: 2
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

        let inFlightRefresh = try XCTUnwrap(viewModel.refreshAddresses())
        let copyTask = Task { @MainActor in
            try await plugin.beginAction(
                ActionInvocation(reference: publicReference, source: .test, mode: .background)
            ).result()
        }
        try await waitUntil {
            let callCounts = await provider.callCounts()
            return callCounts.addresses == 2
        }
        await Task.yield()
        await provider.releaseBlockedAddressCall()

        let result = try await copyTask.value
        await inFlightRefresh.value
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(pasteboard.string(forType: .string), "198.51.100.24")
        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 2)
    }

    func testPrimaryPanelButtonRequestsConfigurationPresentation() {
        let viewModel = IPOverviewViewModel(storage: IPOverviewPluginTestStorage())
        let plugin = IPOverviewPlugin(viewModel: viewModel)
        var didRequestConfigurationPresentation = false
        plugin.requestSettingsPresentation = {
            didRequestConfigurationPresentation = true
        }

        plugin.handleAction(.invokeAction(controlID: IPOverviewPlugin.ControlID.openSettings))

        XCTAssertTrue(didRequestConfigurationPresentation)
    }

    func testPrimaryPanelShowsCopyableLocalAndPublicIPv4Values() async throws {
        let snapshot = IPOverviewSnapshot(
            domesticIPv4: IPOverviewPublicIPResult(
                family: .ipv4,
                route: .domestic,
                ip: "198.51.100.8",
                source: "Domestic Test"
            ),
            domesticIPv6: IPOverviewPublicIPResult(
                family: .ipv6,
                route: .domestic,
                ip: "2001:db8::8",
                source: "Domestic IPv6 Test"
            ),
            internationalIPv4: IPOverviewPublicIPResult(
                family: .ipv4,
                route: .international,
                ip: "203.0.113.8",
                source: "International Test"
            ),
            internationalIPv6: IPOverviewPublicIPResult(
                family: .ipv6,
                route: .international,
                ip: "2001:db8::9",
                source: "International IPv6 Test"
            ),
            localAddresses: [
                IPOverviewLocalAddress(
                    id: "en0-2001:db8::10",
                    interfaceName: "en0",
                    address: "2001:db8::10",
                    family: .ipv6
                ),
                IPOverviewLocalAddress(
                    id: "en0-192.168.1.10",
                    interfaceName: "en0",
                    address: "192.168.1.10",
                    family: .ipv4
                )
            ],
            geoInfoByIP: [:],
            sourceResults: [],
            lastUpdated: Date(),
            errorMessage: nil,
            isRefreshing: false
        )
        let viewModel = IPOverviewViewModel(
            provider: IPOverviewProviderSpy(publicSnapshot: snapshot),
            storage: IPOverviewPluginTestStorage()
        )
        let refreshTask = try XCTUnwrap(viewModel.refreshAddresses())
        await refreshTask.value
        let plugin = IPOverviewPlugin(viewModel: viewModel)
        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.controls)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "203.0.113.8")
        XCTAssertEqual(
            controls.map(\.id),
            [
                IPOverviewPlugin.ControlID.copyLocalIPv4,
                IPOverviewPlugin.ControlID.copyPublicIPv4
            ]
        )
        XCTAssertEqual(
            controls.map(\.actionTitle),
            ["192.168.1.10", "203.0.113.8"]
        )
        XCTAssertEqual(
            controls.map(\.isEnabled),
            [true, true]
        )
    }

    func testOpeningPrimaryPanelRefreshesAddressesWithoutUsingCacheFreshness() async throws {
        let provider = IPOverviewProviderSpy(
            publicSnapshot: testSnapshot(ip: "203.0.113.8", lastUpdated: Date())
        )
        let viewModel = IPOverviewViewModel(
            provider: provider,
            storage: IPOverviewPluginTestStorage()
        )
        let initialRefresh = try XCTUnwrap(viewModel.refreshAddresses())
        await initialRefresh.value
        let plugin = IPOverviewPlugin(viewModel: viewModel)

        plugin.panelSurfaceDidBecomeVisible(.component)
        await Task.yield()
        var callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 1)

        plugin.panelSurfaceDidBecomeVisible(.primary)
        XCTAssertTrue(viewModel.snapshot.isRefreshing)
        try await waitUntil { !viewModel.snapshot.isRefreshing }

        callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 2)
        XCTAssertEqual(callCounts.full, 0)
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

    func testRefreshIfNeededUsesFreshCachedSnapshot() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let storage = IPOverviewPluginTestStorage()
        let cachedSnapshot = testSnapshot(ip: "203.0.113.8", lastUpdated: now)
        let cacheWriter = IPOverviewViewModel(
            provider: IPOverviewProviderSpy(publicSnapshot: .empty, fullSnapshot: cachedSnapshot),
            storage: storage,
            currentDate: { now }
        )

        let cacheWriteTask = try XCTUnwrap(cacheWriter.refresh())
        await cacheWriteTask.value

        let provider = IPOverviewProviderSpy(
            publicSnapshot: testSnapshot(ip: "198.51.100.24", lastUpdated: now)
        )
        let cachedViewModel = IPOverviewViewModel(
            provider: provider,
            storage: storage,
            currentDate: { now.addingTimeInterval(60) }
        )

        XCTAssertEqual(cachedViewModel.snapshot.publicIPv4?.ip, "203.0.113.8")
        XCTAssertNil(cachedViewModel.refreshIfNeeded())
        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 0)
        XCTAssertEqual(callCounts.full, 0)
    }

    func testRefreshIfNeededIgnoresExpiredCache() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let storage = IPOverviewPluginTestStorage()
        let cachedSnapshot = testSnapshot(ip: "203.0.113.8", lastUpdated: now)
        let cacheWriter = IPOverviewViewModel(
            provider: IPOverviewProviderSpy(publicSnapshot: .empty, fullSnapshot: cachedSnapshot),
            storage: storage,
            currentDate: { now }
        )

        let cacheWriteTask = try XCTUnwrap(cacheWriter.refresh())
        await cacheWriteTask.value

        let refreshedSnapshot = testSnapshot(
            ip: "198.51.100.24",
            lastUpdated: now.addingTimeInterval(25 * 60 * 60)
        )
        let provider = IPOverviewProviderSpy(publicSnapshot: refreshedSnapshot)
        let cachedViewModel = IPOverviewViewModel(
            provider: provider,
            storage: storage,
            currentDate: { now.addingTimeInterval(25 * 60 * 60) }
        )

        let refreshTask = try XCTUnwrap(cachedViewModel.refreshIfNeeded())
        await refreshTask.value

        XCTAssertEqual(cachedViewModel.snapshot.publicIPv4?.ip, "198.51.100.24")
        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 1)
        XCTAssertEqual(callCounts.full, 0)
    }

    func testManualRefreshOverridesFreshCache() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let storage = IPOverviewPluginTestStorage()
        let cachedSnapshot = testSnapshot(ip: "203.0.113.8", lastUpdated: now)
        let cacheWriter = IPOverviewViewModel(
            provider: IPOverviewProviderSpy(publicSnapshot: .empty, fullSnapshot: cachedSnapshot),
            storage: storage,
            currentDate: { now }
        )

        let cacheWriteTask = try XCTUnwrap(cacheWriter.refresh())
        await cacheWriteTask.value

        let provider = IPOverviewProviderSpy(
            publicSnapshot: .empty,
            fullSnapshot: testSnapshot(ip: "198.51.100.24", lastUpdated: now.addingTimeInterval(60))
        )
        let cachedViewModel = IPOverviewViewModel(
            provider: provider,
            storage: storage,
            currentDate: { now.addingTimeInterval(60) }
        )

        let refreshTask = try XCTUnwrap(cachedViewModel.refresh())
        await refreshTask.value

        let callCounts = await provider.callCounts()
        XCTAssertEqual(callCounts.addresses, 0)
        XCTAssertEqual(callCounts.full, 1)
    }

    func testPublicIPSourcesAreGroupedByEgressRoute() {
        let domesticIPv4 = IPOverviewPublicIPSource.sources(route: .domestic, family: .ipv4)
        let internationalIPv4 = IPOverviewPublicIPSource.sources(route: .international, family: .ipv4)

        XCTAssertTrue(domesticIPv4.allSatisfy { $0.route == .domestic && $0.family == .ipv4 })
        XCTAssertTrue(internationalIPv4.allSatisfy { $0.route == .international && $0.family == .ipv4 })
        XCTAssertTrue(domesticIPv4.map(\.id).contains("bilibili-v4"))
        XCTAssertTrue(internationalIPv4.map(\.id).contains("ipcheck-v4-json"))
    }

    func testReportTextLabelsDomesticAndInternationalEgress() {
        let snapshot = IPOverviewSnapshot(
            domesticIPv4: IPOverviewPublicIPResult(
                family: .ipv4,
                route: .domestic,
                ip: "198.51.100.8",
                source: "Domestic Test"
            ),
            domesticIPv6: nil,
            internationalIPv4: IPOverviewPublicIPResult(
                family: .ipv4,
                route: .international,
                ip: "203.0.113.8",
                source: "International Test"
            ),
            internationalIPv6: nil,
            localAddresses: [],
            geoInfoByIP: [:],
            sourceResults: [
                IPOverviewSourceResult(
                    id: "domestic-test",
                    family: .ipv4,
                    route: .domestic,
                    source: "Domestic Test IPv4",
                    status: .success("198.51.100.8")
                ),
                IPOverviewSourceResult(
                    id: "international-test",
                    family: .ipv4,
                    route: .international,
                    source: "International Test IPv4",
                    status: .success("203.0.113.8")
                )
            ],
            lastUpdated: nil,
            errorMessage: nil,
            isRefreshing: false
        )
        let report = snapshot.reportText

        XCTAssertTrue(report.contains("国内出口 IPv4：198.51.100.8"))
        XCTAssertTrue(report.contains("国际出口 IPv4：203.0.113.8"))
        XCTAssertTrue(report.contains("- 国内出口 Domestic Test IPv4：198.51.100.8"))
        XCTAssertTrue(report.contains("- 国际出口 International Test IPv4：203.0.113.8"))
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

    func testRefreshAllStartsNetworkQualityMeasurement() async throws {
        let measurement = IPOverviewNetworkQualityMeasurement(
            baseRTTMilliseconds: 42,
            downloadThroughputBitsPerSecond: 120_000_000,
            uploadThroughputBitsPerSecond: 35_000_000,
            downloadResponsivenessRPM: 120,
            uploadResponsivenessRPM: 130,
            downloadPhaseDuration: 3,
            uploadPhaseDuration: 4,
            interfaceName: "en0",
            testEndpoint: "example.apple.com",
            startDate: nil,
            endDate: nil
        )
        let viewModel = IPOverviewViewModel(
            provider: IPOverviewProviderSpy(
                publicSnapshot: .empty,
                fullSnapshot: testSnapshot(ip: "203.0.113.8", lastUpdated: Date())
            ),
            connectivityChecker: IPOverviewConnectivityCheckerSpy(),
            leakTester: IPOverviewLeakTesterSpy(),
            networkQualityMeasurer: IPOverviewNetworkQualityMeasurerSpy(result: .success(measurement)),
            storage: IPOverviewPluginTestStorage()
        )

        viewModel.refreshAll()

        try await waitUntil {
            viewModel.networkQualityState.measurement == measurement
        }
    }

    func testSensitiveInfoVisibilityPersists() {
        let storage = IPOverviewPluginTestStorage()
        let viewModel = IPOverviewViewModel(storage: storage)

        XCTAssertFalse(viewModel.hidesSensitiveInfo)

        viewModel.toggleSensitiveInfoVisibility()

        XCTAssertTrue(viewModel.hidesSensitiveInfo)
        XCTAssertTrue(storage.bool(forKey: "hidesSensitiveInfo"))
    }

    func testMeasureNetworkQualityTracksProgressEvents() async throws {
        let measurement = IPOverviewNetworkQualityMeasurement(
            baseRTTMilliseconds: 50,
            downloadThroughputBitsPerSecond: 90_000_000,
            uploadThroughputBitsPerSecond: 30_000_000,
            downloadResponsivenessRPM: 80,
            uploadResponsivenessRPM: 90,
            downloadPhaseDuration: 3,
            uploadPhaseDuration: 4,
            interfaceName: "en0",
            testEndpoint: "example.apple.com",
            startDate: nil,
            endDate: nil
        )
        let measurer = IPOverviewNetworkQualityBlockingMeasurerSpy(
            result: .success(measurement),
            events: [.download(12), .download(24), .upload(8)]
        )
        let viewModel = IPOverviewViewModel(
            provider: IPOverviewProviderSpy(publicSnapshot: .empty),
            networkQualityMeasurer: measurer,
            storage: IPOverviewPluginTestStorage()
        )

        viewModel.measureNetworkQuality()
        await measurer.waitForProgressEvents()

        guard case .running(let runningProgress) = viewModel.networkQualityState else {
            XCTFail("Expected running state")
            return
        }
        XCTAssertEqual(runningProgress.downloadSamples, [12, 24])
        XCTAssertEqual(runningProgress.uploadSamples, [8])
        XCTAssertEqual(runningProgress.phase, .measuringUpload)

        await measurer.finish()

        try await waitUntil {
            if case .completed(let completedMeasurement, let progress) = viewModel.networkQualityState {
                return completedMeasurement == measurement
                    && progress.downloadSamples == [12, 24]
                    && progress.uploadSamples == [8]
                    && progress.phase == .measuringLatency
            }

            return false
        }

        guard case .completed = viewModel.networkQualityState else {
            XCTFail("Expected completed state")
            return
        }
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

private struct IPOverviewConnectivityCheckerSpy: IPOverviewConnectivityChecking {
    func check(target: IPOverviewConnectivityTarget) async -> IPOverviewConnectivityResult {
        IPOverviewConnectivityResult(id: target.id, target: target, status: .reachable(milliseconds: 12))
    }
}

private struct IPOverviewLeakTesterSpy: IPOverviewLeakTesting {
    func checkWebRTC(target: IPOverviewWebRTCTarget) async -> IPOverviewLeakTestResult {
        IPOverviewLeakTestResult(id: target.id, name: target.name, status: .failure("未获取到出口"))
    }

    func checkDNS(id: String, name: String) async -> IPOverviewLeakTestResult {
        IPOverviewLeakTestResult(
            id: id,
            name: name,
            status: .success(IPOverviewLeakEndpoint(
                ip: "203.0.113.8",
                natType: nil,
                country: "United States",
                countryCode: "US",
                organization: "Example ISP"
            ))
        )
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

private final class IPOverviewNetworkQualityBlockingMeasurerSpy: IPOverviewNetworkQualityMeasuring, @unchecked Sendable {
    let result: IPOverviewNetworkQualityMeasurementResult
    let events: [IPOverviewNetworkQualityProgressEvent]
    private let progressGate = IPOverviewNetworkQualityCompletionGate()
    private let completionGate = IPOverviewNetworkQualityCompletionGate()

    init(
        result: IPOverviewNetworkQualityMeasurementResult,
        events: [IPOverviewNetworkQualityProgressEvent]
    ) {
        self.result = result
        self.events = events
    }

    func measure(
        onProgress: @escaping @Sendable (IPOverviewNetworkQualityProgressEvent) async -> Void
    ) async -> IPOverviewNetworkQualityMeasurementResult {
        for event in events {
            await onProgress(event)
        }
        await progressGate.open()

        await completionGate.wait()

        return result
    }

    func waitForProgressEvents() async {
        await progressGate.wait()
    }

    func finish() async {
        await completionGate.open()
    }
}

private actor IPOverviewNetworkQualityCompletionGate {
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

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now >= deadline {
            XCTFail("Timed out waiting for condition")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
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
