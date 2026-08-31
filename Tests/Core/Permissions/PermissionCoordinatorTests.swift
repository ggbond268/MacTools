import AppKit
import XCTest
import MacToolsPluginKit
import PermissionFlow
@testable import MacTools

@MainActor
final class PermissionCoordinatorTests: XCTestCase {
    func testPermissionFlowResourcesLoadThroughSafePackagedLookup() {
        XCTAssertNotNil(PermissionFlowResources.packageBundle)
        XCTAssertEqual(
            PermissionFlowResources.localizedString(
                for: PermissionFlowResources.accessibilityNameKey,
                defaultValue: "Accessibility",
                localeIdentifier: "en"
            ),
            "Accessibility"
        )
    }

    func testHostMappingKeepsPluginKitStableAndDistinguishesSpecialPermissions() {
        XCTAssertEqual(
            HostPermissionKind.resolve(
                permissionID: "system-audio-recording",
                pluginKind: .screenRecording
            ),
            .systemAudioRecording
        )
        XCTAssertEqual(
            HostPermissionKind.resolve(
                permissionID: "full-disk-access",
                pluginKind: .screenRecording
            ),
            .fullDiskAccess
        )
        XCTAssertEqual(
            HostPermissionKind.resolve(
                permissionID: "screen-recording",
                pluginKind: .screenRecording
            ),
            .screenRecording
        )
    }

    func testAggregationDeduplicatesKindsListsAffectedPluginsAndOrdersAttentionFirst() throws {
        let items = PermissionCenterAggregator.aggregate([
            requirement(
                pluginID: "window-switcher",
                pluginTitle: "Window Switcher",
                permissionID: "accessibility",
                kind: .accessibility,
                isGranted: true
            ),
            requirement(
                pluginID: "input-remapping",
                pluginTitle: "Input Remapping",
                permissionID: "accessibility",
                kind: .accessibility,
                isGranted: false
            ),
            requirement(
                pluginID: "appearance",
                pluginTitle: "Appearance",
                permissionID: "automation",
                kind: .automation,
                isGranted: false,
                statusTone: .neutral
            ),
            requirement(
                pluginID: "translator",
                pluginTitle: "Translator",
                permissionID: "screen-recording",
                kind: .screenRecording,
                isGranted: true
            ),
        ])

        XCTAssertEqual(items.map(\.kind), [.accessibility, .automation, .screenRecording])
        let accessibility = try XCTUnwrap(items.first { $0.kind == .accessibility })
        XCTAssertEqual(accessibility.status, .attention)
        XCTAssertEqual(
            accessibility.affectedFeatures.map(\.pluginID),
            ["input-remapping", "window-switcher"]
        )
        XCTAssertEqual(items.first { $0.kind == .automation }?.status, .onDemand)
        XCTAssertEqual(items.first { $0.kind == .screenRecording }?.status, .granted)
    }

    func testActionsUseGuidanceForSharedPermissionsAndPluginAdaptersForSpecialCases() throws {
        let notificationCenter = NotificationCenter()
        var guidedKinds: [HostPermissionKind] = []
        var specializedActions: [String] = []
        let coordinator = PermissionCoordinator(
            notificationCenter: notificationCenter,
            specializedActionHandler: { pluginID, permissionID in
                specializedActions.append("\(pluginID):\(permissionID)")
            },
            refreshHandler: {},
            guidanceHandler: { kind, _ in
                guidedKinds.append(kind)
            }
        )
        coordinator.replaceRequirements([
            requirement(pluginID: "input", permissionID: "accessibility", kind: .accessibility),
            requirement(pluginID: "calendar", permissionID: "events", kind: .calendarFullAccess),
            requirement(pluginID: "audio", permissionID: "system-audio-recording", kind: .systemAudioRecording),
            requirement(pluginID: "finder", permissionID: "finder", kind: .finderExtension),
            requirement(pluginID: "appearance", permissionID: "automation", kind: .automation),
        ])

        for item in coordinator.items {
            coordinator.performAction(for: item)
        }

        XCTAssertEqual(Set(guidedKinds), [.accessibility, .automation])
        XCTAssertEqual(
            Set(specializedActions),
            ["calendar:events", "audio:system-audio-recording", "finder:finder"]
        )
    }

    func testActivationRefreshesState() async {
        let notificationCenter = NotificationCenter()
        var refreshCount = 0
        let coordinator = PermissionCoordinator(
            notificationCenter: notificationCenter,
            specializedActionHandler: { _, _ in },
            refreshHandler: { refreshCount += 1 },
            guidanceHandler: { _, _ in }
        )

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(refreshCount, 1)
        _ = coordinator
    }

    func testReplacingRequirementsReflectsPluginRemovalAndUpdatedState() throws {
        let coordinator = PermissionCoordinator(
            notificationCenter: NotificationCenter(),
            specializedActionHandler: { _, _ in },
            refreshHandler: {},
            guidanceHandler: { _, _ in }
        )
        coordinator.replaceRequirements([
            requirement(pluginID: "first", permissionID: "accessibility", kind: .accessibility),
            requirement(pluginID: "second", permissionID: "accessibility", kind: .accessibility),
        ])
        XCTAssertEqual(coordinator.items.first?.affectedFeatures.count, 2)

        coordinator.replaceRequirements([
            requirement(
                pluginID: "second",
                permissionID: "accessibility",
                kind: .accessibility,
                isGranted: true
            ),
        ])

        let item = try XCTUnwrap(coordinator.items.first)
        XCTAssertEqual(item.affectedFeatures.map(\.pluginID), ["second"])
        XCTAssertEqual(item.status, .granted)
    }

    private func requirement(
        pluginID: String,
        pluginTitle: String? = nil,
        permissionID: String,
        kind: HostPermissionKind,
        isGranted: Bool = false,
        statusTone: PluginStatusTone? = nil
    ) -> PermissionCenterRequirement {
        PermissionCenterRequirement(
            pluginID: pluginID,
            pluginTitle: pluginTitle ?? pluginID,
            permissionID: permissionID,
            kind: kind,
            description: "Uses \(permissionID)",
            isGranted: isGranted,
            footnote: nil,
            statusText: nil,
            statusSystemImage: nil,
            statusTone: statusTone
        )
    }
}
