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
        XCTAssertEqual(
            HostPermissionKind.resolve(
                permissionID: "finder-extension",
                pluginKind: .automation
            ),
            .finderExtension
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

    func testAggregationUsesAttentionPresentationAndFootnoteForMixedAutomationStates() throws {
        let items = PermissionCenterAggregator.aggregate([
            requirement(
                pluginID: "appearance",
                pluginTitle: "Appearance",
                permissionID: "automation",
                kind: .automation,
                isGranted: false,
                footnote: "Requested when needed",
                statusText: "On Demand",
                statusTone: .neutral
            ),
            requirement(
                pluginID: "empty-trash",
                pluginTitle: "Empty Trash",
                permissionID: "automation",
                kind: .automation,
                isGranted: false,
                footnote: "Finder denied access",
                statusText: "Authorization Failed",
                statusTone: .caution
            ),
        ])

        let automation = try XCTUnwrap(items.first)
        XCTAssertEqual(automation.status, .attention)
        XCTAssertEqual(automation.statusText, "Authorization Failed")
        XCTAssertEqual(automation.statusTone, .caution)
        XCTAssertNotNil(automation.footnote)
        XCTAssertEqual(
            automation.affectedFeatures.map(\.footnote),
            ["Requested when needed", "Finder denied access"]
        )
    }

    func testAggregationPreservesGrantedOnDemandSemanticsPerFeature() throws {
        let item = try XCTUnwrap(PermissionCenterAggregator.aggregate([
            requirement(
                pluginID: "translator",
                permissionID: "automation",
                kind: .automation,
                isGranted: true,
                statusText: "On Demand",
                statusSystemImage: "cursorarrow.click.2",
                statusTone: .neutral
            ),
        ]).first)

        XCTAssertEqual(item.status, .onDemand)
        XCTAssertEqual(item.statusText, "On Demand")
        XCTAssertEqual(item.affectedFeatures.first?.status, .onDemand)
        XCTAssertEqual(item.affectedFeatures.first?.statusSystemImage, "cursorarrow.click.2")
    }

    func testAggregationPreservesDistinctFeatureFootnotesAndGroupGuidance() throws {
        let item = try XCTUnwrap(PermissionCenterAggregator.aggregate([
            requirement(
                pluginID: "appearance",
                pluginTitle: "Appearance",
                permissionID: "automation-a",
                kind: .automation,
                footnote: "Appearance-specific note",
                statusTone: .neutral
            ),
            requirement(
                pluginID: "empty-trash",
                pluginTitle: "Empty Trash",
                permissionID: "automation-b",
                kind: .automation,
                footnote: "Empty Trash-specific error",
                statusTone: .caution
            ),
        ]).first)

        XCTAssertEqual(
            item.affectedFeatures.map(\.footnote),
            ["Appearance-specific note", "Empty Trash-specific error"]
        )
        XCTAssertNotNil(item.footnote)
        XCTAssertNotEqual(item.footnote, "Appearance-specific note")
        XCTAssertNotEqual(item.footnote, "Empty Trash-specific error")
    }

    func testFeatureStatusTextUsesCustomPresentationAndSemanticFallbacks() throws {
        let item = try XCTUnwrap(PermissionCenterAggregator.aggregate([
            requirement(
                pluginID: "custom",
                pluginTitle: "Custom",
                permissionID: "automation-custom",
                kind: .automation,
                statusText: "Ask When Used",
                statusTone: .neutral
            ),
            requirement(
                pluginID: "granted",
                pluginTitle: "Granted",
                permissionID: "automation-granted",
                kind: .automation,
                isGranted: true
            ),
            requirement(
                pluginID: "needs-access",
                pluginTitle: "Needs Access",
                permissionID: "automation-denied",
                kind: .automation
            ),
        ]).first)

        let features = Dictionary(uniqueKeysWithValues: item.affectedFeatures.map {
            ($0.pluginID, $0)
        })
        XCTAssertEqual(
            permissionFeatureStatusText(for: try XCTUnwrap(features["custom"])),
            "Ask When Used"
        )
        XCTAssertEqual(
            permissionFeatureStatusText(for: try XCTUnwrap(features["granted"])),
            AppL10n.plugins("plugin.permission.granted", defaultValue: "已授权")
        )
        XCTAssertEqual(
            permissionFeatureStatusText(for: try XCTUnwrap(features["needs-access"])),
            AppL10n.plugins("plugin.permission.notGranted", defaultValue: "未授权")
        )
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
            requirement(pluginID: "input", permissionID: "accessibility", kind: .accessibility),
            requirement(pluginID: "calendar", permissionID: "events", kind: .calendarFullAccess),
            requirement(pluginID: "audio", permissionID: "system-audio-recording", kind: .systemAudioRecording),
            requirement(pluginID: "finder", permissionID: "finder", kind: .finderExtension),
            requirement(pluginID: "appearance", permissionID: "automation", kind: .automation),
            requirement(pluginID: "disk-clean", permissionID: "full-disk-access", kind: .fullDiskAccess),
        ])

        for item in coordinator.items {
            coordinator.performAction(for: item)
        }

        XCTAssertEqual(Set(guidedKinds), [.accessibility, .automation])
        XCTAssertEqual(
            Set(specializedActions),
            [
                "calendar:events",
                "audio:system-audio-recording",
                "disk-clean:full-disk-access",
                "finder:finder",
            ]
        )
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

    func testSystemAudioTargetSurvivesPromptActivationUntilSettingsReturn() async throws {
        let notificationCenter = NotificationCenter()
        var refreshedTargets: [[PermissionCenterAffectedFeature]] = []
        let coordinator = PermissionCoordinator(
            notificationCenter: notificationCenter,
            specializedActionHandler: { _, _ in },
            refreshHandler: { refreshedTargets.append($0) },
            guidanceHandler: { _, _ in }
        )
        coordinator.replaceRequirements([
            requirement(
                pluginID: "audio",
                permissionID: "system-audio-recording",
                kind: .systemAudioRecording
            ),
        ])
        performPermissionCenterAction(
            coordinator: coordinator,
            item: try XCTUnwrap(coordinator.items.first),
            sourceFrame: nil
        )

        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(refreshedTargets.count, 2)
        XCTAssertEqual(refreshedTargets.flatMap { $0 }.map(\.pluginID), ["audio", "audio"])
    }

    func testPassiveRefreshDoesNotProbeGrantedSystemAudio() throws {
        var refreshedTargets: [[PermissionCenterAffectedFeature]] = []
        let coordinator = PermissionCoordinator(
            notificationCenter: NotificationCenter(),
            specializedActionHandler: { _, _ in },
            refreshHandler: { refreshedTargets.append($0) },
            guidanceHandler: { _, _ in }
        )
        coordinator.replaceRequirements([
            requirement(
                pluginID: "audio",
                permissionID: "system-audio-recording",
                kind: .systemAudioRecording,
                isGranted: true
            ),
        ])
        coordinator.refresh()

        XCTAssertEqual(refreshedTargets, [[]])
    }

    func testExplicitGrantedSystemAudioActionRequestsTargetedRecheck() throws {
        var refreshedTargets: [[PermissionCenterAffectedFeature]] = []
        let coordinator = PermissionCoordinator(
            notificationCenter: NotificationCenter(),
            specializedActionHandler: { _, _ in },
            refreshHandler: { refreshedTargets.append($0) },
            guidanceHandler: { _, _ in }
        )
        coordinator.replaceRequirements([
            requirement(
                pluginID: "audio",
                permissionID: "system-audio-recording",
                kind: .systemAudioRecording,
                isGranted: true
            ),
        ])

        coordinator.performAction(for: try XCTUnwrap(coordinator.items.first))

        XCTAssertEqual(refreshedTargets.count, 1)
        XCTAssertEqual(refreshedTargets.first?.map(\.pluginID), ["audio"])
    }

    func testPermissionGuidanceSourceFrameOnlyUsesPointerActivation() throws {
        let location = CGPoint(x: 100, y: 200)

        XCTAssertEqual(
            permissionGuidanceSourceFrame(eventType: .leftMouseUp, mouseLocation: location),
            CGRect(x: 84, y: 184, width: 32, height: 32)
        )
        XCTAssertNil(permissionGuidanceSourceFrame(eventType: .keyUp, mouseLocation: location))
        XCTAssertNil(permissionGuidanceSourceFrame(eventType: nil, mouseLocation: location))
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
