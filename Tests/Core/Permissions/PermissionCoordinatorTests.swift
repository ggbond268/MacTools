import AppKit
import XCTest
import MacToolsPluginKit
import PermissionFlow
@testable import MacTools

@MainActor
final class PermissionCoordinatorTests: XCTestCase {

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
            refreshHandler: { _ in },
            guidanceHandler: { kind, _ in
                guidedKinds.append(kind)
            }
        )
        coordinator.replaceRequirements([
            requirement(pluginID: "accessibility", permissionID: "accessibility", kind: .accessibility),
            requirement(pluginID: "input", permissionID: "input-monitoring", kind: .inputMonitoring),
            requirement(pluginID: "screen", permissionID: "screen-recording", kind: .screenRecording),
            requirement(pluginID: "calendar", permissionID: "events", kind: .calendarFullAccess),
            requirement(pluginID: "audio", permissionID: "system-audio-recording", kind: .systemAudioRecording),
            requirement(pluginID: "finder", permissionID: "finder", kind: .finderExtension),
            requirement(pluginID: "appearance", permissionID: "automation", kind: .automation),
            requirement(pluginID: "disk-clean", permissionID: "full-disk-access", kind: .fullDiskAccess),
        ])

        for item in coordinator.items {
            coordinator.performAction(for: item)
        }

        XCTAssertEqual(
            Set(guidedKinds),
            [.accessibility, .inputMonitoring, .screenRecording, .automation, .fullDiskAccess]
        )
        XCTAssertEqual(
            Set(specializedActions),
            [
                "calendar:events",
                "audio:system-audio-recording",
                "finder:finder",
            ]
        )
    }

    func testFullDiskAccessUsesGuidanceAndRefreshesSelectedTargetOnReturn() async throws {
        let notificationCenter = NotificationCenter()
        var guidedKinds: [HostPermissionKind] = []
        var guidedSourceFrames: [CGRect?] = []
        var specializedActions: [String] = []
        var refreshedTargets: [[PermissionCenterAffectedFeature]] = []
        let coordinator = PermissionCoordinator(
            notificationCenter: notificationCenter,
            specializedActionHandler: { pluginID, permissionID in
                specializedActions.append("\(pluginID):\(permissionID)")
            },
            refreshHandler: { refreshedTargets.append($0) },
            guidanceHandler: { kind, sourceFrame in
                guidedKinds.append(kind)
                guidedSourceFrames.append(sourceFrame)
            }
        )
        coordinator.replaceRequirements([
            requirement(
                pluginID: "disk-clean",
                permissionID: "full-disk-access",
                kind: .fullDiskAccess
            ),
        ])
        let sourceFrame = CGRect(x: 10, y: 20, width: 32, height: 32)

        XCTAssertTrue(coordinator.performAction(
            pluginID: "disk-clean",
            permissionID: "full-disk-access",
            sourceFrame: sourceFrame
        ))
        XCTAssertEqual(guidedKinds, [.fullDiskAccess])
        XCTAssertEqual(guidedSourceFrames, [sourceFrame])
        XCTAssertTrue(specializedActions.isEmpty)

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(refreshedTargets.count, 1)
        XCTAssertEqual(refreshedTargets.first?.map(\.pluginID), ["disk-clean"])
    }

    func testDirectActionsUseTheSelectedFeatureAndRefreshGrantedTargets() {
        var specializedActions: [String] = []
        var refreshCount = 0
        let coordinator = PermissionCoordinator(
            notificationCenter: NotificationCenter(),
            specializedActionHandler: { pluginID, permissionID in
                specializedActions.append("\(pluginID):\(permissionID)")
            },
            refreshHandler: { _ in refreshCount += 1 },
            guidanceHandler: { _, _ in }
        )
        coordinator.replaceRequirements([
            requirement(
                pluginID: "calendar-a",
                pluginTitle: "A Calendar",
                permissionID: "events-a",
                kind: .calendarFullAccess
            ),
            requirement(
                pluginID: "calendar-b",
                pluginTitle: "B Calendar",
                permissionID: "events-b",
                kind: .calendarFullAccess
            ),
            requirement(
                pluginID: "input",
                permissionID: "accessibility",
                kind: .accessibility,
                isGranted: true
            ),
        ])

        XCTAssertTrue(coordinator.performAction(pluginID: "calendar-b", permissionID: "events-b"))
        XCTAssertEqual(specializedActions, ["calendar-b:events-b"])

        XCTAssertTrue(coordinator.performAction(pluginID: "input", permissionID: "accessibility"))
        XCTAssertEqual(refreshCount, 1)
    }

    func testActivationRefreshRequiresPendingUserRoundTrip() async throws {
        let notificationCenter = NotificationCenter()
        var refreshCount = 0
        let coordinator = PermissionCoordinator(
            notificationCenter: notificationCenter,
            specializedActionHandler: { _, _ in },
            refreshHandler: { _ in refreshCount += 1 },
            guidanceHandler: { _, _ in }
        )

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(refreshCount, 0)

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(refreshCount, 0)

        coordinator.replaceRequirements([
            requirement(
                pluginID: "appearance",
                permissionID: "automation",
                kind: .automation,
                statusTone: .neutral
            ),
        ])
        performPermissionCenterAction(
            coordinator: coordinator,
            item: try XCTUnwrap(coordinator.items.first),
            sourceFrame: nil
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
            refreshHandler: { _ in },
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
        footnote: String? = nil,
        statusText: String? = nil,
        statusSystemImage: String? = nil,
        statusTone: PluginStatusTone? = nil
    ) -> PermissionCenterRequirement {
        PermissionCenterRequirement(
            pluginID: pluginID,
            pluginTitle: pluginTitle ?? pluginID,
            permissionID: permissionID,
            kind: kind,
            description: "Uses \(permissionID)",
            isGranted: isGranted,
            footnote: footnote,
            statusText: statusText,
            statusSystemImage: statusSystemImage,
            statusTone: statusTone
        )
    }
}
