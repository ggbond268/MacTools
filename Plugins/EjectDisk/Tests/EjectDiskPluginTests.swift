import XCTest
import MacToolsPluginKit
@testable import EjectDiskPlugin

@MainActor
final class EjectDiskPluginTests: XCTestCase {
    func testWidgetDiscoversVolumesAndSharesVisibilityWithRow() async throws {
        let probe = VolumeDiscoveryProbe(volumes: [makeVolume("Disk4")])
        let plugin = EjectDiskPlugin(discoverVolumes: { try await probe.discover() })
        let items = plugin.panelItems
        let rowVisibility = try XCTUnwrap(items.first { $0.id == "control" }?.visibilityHandler)
        let widgetVisibility = try XCTUnwrap(items.first { $0.id == "quick-control" }?.visibilityHandler)
        widgetVisibility(true)
        rowVisibility(true)
        rowVisibility(false)
        await waitUntil { plugin.rowState.isEnabled }
        let requestCount = await probe.requestCountValue()
        XCTAssertEqual(requestCount, 1, "Both renderers share one discovery and hiding the row keeps the widget active")
        widgetVisibility(false)
        widgetVisibility(true)
        await waitUntil { plugin.rowState.isEnabled }
        let reopenedCount = await probe.requestCountValue()
        XCTAssertEqual(reopenedCount, 2)
        widgetVisibility(false)
    }

    func testRefreshDoesNotDiscoverVolumesWhilePanelIsHidden() async {
        let probe = VolumeDiscoveryProbe(volumes: [makeVolume("Disk4")])
        let plugin = EjectDiskPlugin(discoverVolumes: { try await probe.discover() })

        plugin.refresh()
        plugin.panelItemDidBecomeVisible("widget")
        await Task.yield()

        let requestCount = await probe.requestCountValue()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(plugin.rowState.isEnabled)
    }

    func testOpeningPrimaryPanelDiscoversMountedEjectableVolumes() async {
        let probe = VolumeDiscoveryProbe(volumes: [
            makeVolume("Disk4"),
            makeVolume("Disk5")
        ])
        let plugin = EjectDiskPlugin(discoverVolumes: { try await probe.discover() })

        plugin.panelItemDidBecomeVisible("control")

        XCTAssertEqual(plugin.rowState.subtitle, "正在检测...")
        await waitUntil { plugin.rowState.subtitle == "2 个可推出的磁盘" }
        let requestCount = await probe.requestCountValue()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(plugin.rowState.isEnabled)
    }

    func testDiscoveryFailureIsReportedInsteadOfSilentlyLookingEmpty() async {
        let plugin = EjectDiskPlugin(discoverVolumes: { throw VolumeDiscoveryProbeError.failed })

        plugin.panelItemDidBecomeVisible("control")

        await waitUntil { plugin.rowState.errorMessage != nil }
        XCTAssertEqual(plugin.rowState.subtitle, "无可推出的磁盘")
        XCTAssertFalse(plugin.rowState.isEnabled)
    }

    func testSuccessfulEjectRemovesVolumesFromSnapshot() async {
        let volumes = [
            makeVolume("Disk4"),
            makeVolume("Disk5")
        ]
        let discoveryProbe = VolumeDiscoveryProbe(volumes: volumes)
        let ejectProbe = VolumeEjectProbe()
        let plugin = EjectDiskPlugin(
            discoverVolumes: { try await discoveryProbe.discover() },
            ejectVolume: { try await ejectProbe.eject($0) }
        )
        plugin.panelItemDidBecomeVisible("control")
        await waitUntil { plugin.rowState.isEnabled }

        plugin.handleAction(.invokeAction(controlID: "execute"))

        await waitUntil { !plugin.rowState.isEnabled && plugin.rowState.subtitle == "无可推出的磁盘" }
        let ejectedIdentifiers = await ejectProbe.ejectedIdentifiers()
        XCTAssertEqual(ejectedIdentifiers, ["/Volumes/Disk4", "/Volumes/Disk5"])
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testPartialEjectFailureKeepsOnlyFailedVolume() async {
        let volumes = [
            makeVolume("Disk4"),
            makeVolume("Disk5")
        ]
        let discoveryProbe = VolumeDiscoveryProbe(volumes: volumes)
        let ejectProbe = VolumeEjectProbe(failingIdentifiers: ["/Volumes/Disk5"])
        let plugin = EjectDiskPlugin(
            discoverVolumes: { try await discoveryProbe.discover() },
            ejectVolume: { try await ejectProbe.eject($0) }
        )
        plugin.panelItemDidBecomeVisible("control")
        await waitUntil { plugin.rowState.isEnabled }

        plugin.handleAction(.invokeAction(controlID: "execute"))

        await waitUntil { plugin.rowState.subtitle == "1 个可推出的磁盘" }
        XCTAssertTrue(plugin.rowState.isEnabled)
        XCTAssertNotNil(plugin.rowState.errorMessage)
        let ejectedIdentifiers = await ejectProbe.ejectedIdentifiers()
        XCTAssertEqual(ejectedIdentifiers, ["/Volumes/Disk4", "/Volumes/Disk5"])
    }

    func testCanonicalActionDiscoversAndEjectsWithoutOpeningThePanel() async throws {
        let volumes = [makeVolume("Disk4"), makeVolume("Disk5")]
        let discoveryProbe = VolumeDiscoveryProbe(volumes: volumes)
        let ejectProbe = VolumeEjectProbe()
        let plugin = EjectDiskPlugin(
            discoverVolumes: { try await discoveryProbe.discover() },
            ejectVolume: { try await ejectProbe.eject($0) }
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertFalse(definition.capabilities.contains(.cancellable))
        XCTAssertEqual(definition.executionTimeoutSeconds, 120)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        let ejectedIdentifiers = await ejectProbe.ejectedIdentifiers()
        XCTAssertEqual(ejectedIdentifiers, ["/Volumes/Disk4", "/Volumes/Disk5"])
    }

    func testEjectEligibilityIncludesDiskImagesAndRemovableMedia() {
        XCTAssertTrue(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/Vorssaint",
            isInternal: nil,
            isRemovable: true,
            isEjectable: true,
            isLocal: true,
            isUnmountable: true
        ))
    }

    func testEjectEligibilityIncludesFixedExternalAndNetworkVolumes() {
        XCTAssertTrue(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/ExternalSSD",
            isInternal: false,
            isRemovable: false,
            isEjectable: false,
            isLocal: true,
            isUnmountable: true
        ))
        XCTAssertTrue(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/Shared",
            isInternal: nil,
            isRemovable: false,
            isEjectable: false,
            isLocal: false,
            isUnmountable: true
        ))
    }

    func testEjectEligibilityRejectsStartupAndUnknownVolumes() {
        XCTAssertFalse(EjectDiskService.shouldOfferEject(
            mountPath: "/",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isLocal: true,
            isUnmountable: true
        ))
        XCTAssertFalse(EjectDiskService.shouldOfferEject(
            mountPath: "/Volumes/Unknown",
            isInternal: nil,
            isRemovable: nil,
            isEjectable: nil,
            isLocal: nil,
            isUnmountable: false
        ))
        XCTAssertFalse(EjectDiskService.shouldOfferEject(
            mountPath: "/System/Volumes/Hidden",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isLocal: true,
            isUnmountable: true,
            isBrowsable: false
        ))
    }

    func testVolumesOnSameDeviceAreEjectedOnce() {
        let volumes = [
            makeVolume("ExternalData", deviceIdentifier: "disk8"),
            makeVolume("ExternalBackup", deviceIdentifier: "disk8"),
            makeVolume("DiskImage", deviceIdentifier: "disk9")
        ]

        let targets = EjectDiskService.deduplicate(volumes)

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets[0].deviceIdentifier, "disk8")
        XCTAssertEqual(targets[0].mountURLs.count, 2)
        XCTAssertEqual(targets[1].deviceIdentifier, "disk9")
    }

    private func makeVolume(
        _ name: String,
        deviceIdentifier: String? = nil
    ) -> EjectableVolume {
        EjectableVolume(
            mountURL: URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true),
            name: name,
            deviceIdentifier: deviceIdentifier
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<40 {
            if condition() {
                return
            }
            await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private actor VolumeDiscoveryProbe {
    private var requestCount = 0
    private let volumes: [EjectableVolume]

    init(volumes: [EjectableVolume]) {
        self.volumes = volumes
    }

    func discover() throws -> [EjectableVolume] {
        requestCount += 1
        return volumes
    }

    func requestCountValue() -> Int {
        requestCount
    }
}

private actor VolumeEjectProbe {
    private var identifiers: [String] = []
    private let failingIdentifiers: Set<String>

    init(failingIdentifiers: Set<String> = []) {
        self.failingIdentifiers = failingIdentifiers
    }

    func eject(_ volume: EjectableVolume) throws {
        identifiers.append(volume.id)
        if failingIdentifiers.contains(volume.id) {
            throw VolumeEjectProbeError.failed
        }
    }

    func ejectedIdentifiers() -> [String] {
        identifiers
    }
}

private enum VolumeEjectProbeError: Error {
    case failed
}

private enum VolumeDiscoveryProbeError: Error {
    case failed
}
