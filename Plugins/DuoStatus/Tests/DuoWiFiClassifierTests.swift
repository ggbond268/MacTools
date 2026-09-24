import XCTest
@testable import DuoStatusPlugin

final class DuoWiFiClassifierTests: XCTestCase {
    private func classify(
        powerOn: Bool = true,
        serviceActive: Bool = true,
        isIBSS: Bool = false,
        sharingActive: Bool = false,
        pathSatisfied: Bool? = true,
        usesWiFi: Bool = true,
        isExpensive: Bool = false
    ) -> DuoWiFiClassification {
        DuoWiFiClassifier.classify(
            powerOn: powerOn,
            serviceActive: serviceActive,
            isIBSS: isIBSS,
            sharingActive: sharingActive,
            pathSatisfied: pathSatisfied,
            usesWiFi: usesWiFi,
            isExpensive: isExpensive
        )
    }

    func testOffBeatsEveryOtherSignal() {
        XCTAssertEqual(
            classify(
                powerOn: false,
                serviceActive: true,
                isIBSS: true,
                sharingActive: true,
                pathSatisfied: false,
                isExpensive: true
            ),
            .off
        )
    }

    func testNotAssociatedBeatsSharingAndPath() {
        XCTAssertEqual(
            classify(serviceActive: false, isIBSS: true, sharingActive: true, pathSatisfied: false),
            .notAssociated
        )
    }

    func testSharedBeatsTemporaryAndPath() {
        XCTAssertEqual(classify(isIBSS: true, sharingActive: true, pathSatisfied: false), .shared)
    }

    func testTemporaryBeatsPath() {
        XCTAssertEqual(classify(isIBSS: true, pathSatisfied: false, isExpensive: true), .temporary)
    }

    func testHotspotWhenSatisfiedExpensiveWiFi() {
        XCTAssertEqual(classify(pathSatisfied: true, usesWiFi: true, isExpensive: true), .hotspot)
    }

    func testExpensivePathOverAnotherInterfaceIsNotHotspot() {
        XCTAssertEqual(classify(pathSatisfied: true, usesWiFi: false, isExpensive: true), .connected)
    }

    func testNoInternetWhenPathUnsatisfied() {
        XCTAssertEqual(classify(pathSatisfied: false, isExpensive: true), .noInternet)
    }

    func testUnknownPathDefaultsToConnected() {
        XCTAssertEqual(classify(pathSatisfied: nil, usesWiFi: false, isExpensive: true), .connected)
    }

    func testConnectedByDefault() {
        XCTAssertEqual(classify(), .connected)
    }

    // MARK: - Mapping into the snapshot

    func testPreciseStatesKeepTheirSignalLevel() {
        let hotspot = DuoSystemStatusReader.wifi(classification: .hotspot, rssi: -58)
        XCTAssertEqual(hotspot.state, .hotspot)
        XCTAssertEqual(hotspot.signalLevel, 3)

        let shared = DuoSystemStatusReader.wifi(classification: .shared, rssi: -40)
        XCTAssertEqual(shared.state, .shared)
        XCTAssertEqual(shared.signalLevel, 4)

        let noInternet = DuoSystemStatusReader.wifi(classification: .noInternet, rssi: 0)
        XCTAssertEqual(noInternet.state, .noInternet, "a missing RSSI must not hide the precise state")
        XCTAssertEqual(noInternet.signalLevel, 0)
    }

    func testConnectedWithoutUsableRSSIStaysUnavailable() {
        XCTAssertEqual(DuoSystemStatusReader.wifi(classification: .connected, rssi: -70).state, .connected(level: 2))
        XCTAssertEqual(DuoSystemStatusReader.wifi(classification: .connected, rssi: 0).state, .unavailable)
        XCTAssertEqual(DuoSystemStatusReader.wifi(classification: .off, rssi: -50).state, .off)
        XCTAssertEqual(DuoSystemStatusReader.wifi(classification: .notAssociated, rssi: -50).state, .disconnected)
    }

    func testSnapshotReportsDotsForPreciseStates() {
        var snapshot = DuoSystemStatusSnapshot.unknown
        snapshot.wifi = .hotspot
        snapshot.wifiSignalLevel = 2
        XCTAssertEqual(snapshot.wifiLevel, 2)

        snapshot.wifi = .connected(level: 4)
        XCTAssertEqual(snapshot.wifiLevel, 4, "an explicit level wins over the stored strength")

        snapshot.wifi = .off
        snapshot.wifiSignalLevel = 9
        XCTAssertEqual(snapshot.wifiLevel, 4, "the level is clamped to the four dots")
    }

    // MARK: - Path snapshot

    func testPathSnapshotPrefersWiredOverWiFi() {
        let wired = DuoNetworkPathSnapshot(status: .connected, usesWiFi: true, usesWiredEthernet: true)
        XCTAssertEqual(wired.connectionKind, .ethernet)
        XCTAssertTrue(wired.isSatisfied)

        XCTAssertEqual(
            DuoNetworkPathSnapshot(status: .connected, usesWiFi: true).connectionKind,
            .wifi
        )
        XCTAssertEqual(DuoNetworkPathSnapshot(status: .connected).connectionKind, .other)
    }

    func testUnsatisfiedPathHasNoConnectionKind() {
        XCTAssertNil(DuoNetworkPathSnapshot(status: .disconnected, usesWiFi: true).connectionKind)
        XCTAssertNil(DuoNetworkPathSnapshot().connectionKind)
        XCTAssertFalse(DuoNetworkPathSnapshot(status: .requiresConnection).isSatisfied)
    }
}
