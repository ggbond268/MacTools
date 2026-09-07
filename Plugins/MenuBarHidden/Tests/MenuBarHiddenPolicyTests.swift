// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import XCTest
@testable import MenuBarHiddenPlugin

@MainActor
final class MenuBarHiddenPolicyTests: XCTestCase {

    func testSnapshotCountsReflectSections() {
        let visible = makeItem(pid: 41, title: "Visible", bounds: CGRect(x: 120, y: 0, width: 20, height: 20))
        let hidden = makeItem(pid: 42, title: "Hidden", bounds: CGRect(x: 60, y: 0, width: 20, height: 20))

        let snapshot = MenuBarHiddenSnapshot(
            visibleItems: [visible],
            hiddenItems: [hidden],
            alwaysHiddenItems: [],
            permissions: MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: true)
        )

        XCTAssertEqual(snapshot.hiddenCount, 1)
        XCTAssertEqual(snapshot.allItems.map(\.tag), [visible.tag, hidden.tag])
    }

    func testLayoutPolicyKeepsHostIconVisible() {
        let dividerBounds = CGRect(x: 100, y: 0, width: 10, height: 20)
        let host = makeItem(
            pid: ProcessInfo.processInfo.processIdentifier,
            title: "MacTools",
            bounds: CGRect(x: 60, y: 0, width: 20, height: 20)
        )
        let hidden = makeItem(pid: 42, title: "Hidden", bounds: CGRect(x: 60, y: 0, width: 20, height: 20))
        let visible = makeItem(pid: 43, title: "Visible", bounds: CGRect(x: 120, y: 0, width: 20, height: 20))

        XCTAssertEqual(
            MenuBarHiddenLayoutPolicy.hiddenItems(
                from: [host, hidden, visible],
                hiddenDividerBounds: dividerBounds
            ).map(\.tag),
            [hidden.tag]
        )
        XCTAssertEqual(
            MenuBarHiddenLayoutPolicy.visibleItems(
                from: [host, hidden, visible],
                hiddenDividerBounds: dividerBounds
            ).map(\.tag),
            [host.tag, visible.tag]
        )
    }

    func testStoredLayoutPolicyDefaultsNewHideableItemsToHidden() {
        let visible = makeItem(namespace: "com.example.visible", title: "Item")
        let hidden = makeItem(namespace: "com.example.hidden", title: "Item")
        let newlySeen = makeItem(namespace: "com.example.new", title: "Item")
        let host = makeItem(pid: ProcessInfo.processInfo.processIdentifier, title: "MacTools")
        let storedLayout = MenuBarHiddenStoredLayout(
            visibleItemStableKeys: [visible.tag.stableKey],
            hiddenItemStableKeys: [hidden.tag.stableKey],
            alwaysHiddenItemStableKeys: [],
            isAlwaysHiddenEnabled: false
        )

        let layout = MenuBarHiddenStoredLayoutPolicy.appendNewItemsToHiddenByDefault(
            items: [visible, hidden, newlySeen, host],
            storedLayout: storedLayout
        )

        XCTAssertEqual(layout.visibleItemStableKeys, [visible.tag.stableKey, host.tag.stableKey])
        XCTAssertEqual(layout.hiddenItemStableKeys, [hidden.tag.stableKey, newlySeen.tag.stableKey])
    }

    func testSystemItemsThatShouldNotBeHiddenAreRejected() {
        let audioVideo = makeItem(namespace: "com.apple.controlcenter", title: "AudioVideoModule")
        let normalItem = makeItem(namespace: "com.example.app", title: "Item")

        XCTAssertTrue(MenuBarHiddenLayoutPolicy.shouldRejectMoveToSection(item: audioVideo, section: .hidden))
        XCTAssertTrue(MenuBarHiddenLayoutPolicy.shouldRejectMoveToSection(item: audioVideo, section: .alwaysHidden))
        XCTAssertFalse(MenuBarHiddenLayoutPolicy.shouldRejectMoveToSection(item: audioVideo, section: .visible))
        XCTAssertFalse(MenuBarHiddenLayoutPolicy.shouldRejectMoveToSection(item: normalItem, section: .hidden))
    }

    func testAlwaysHiddenRestoreCandidatesOnlyIncludeRecordedVisibleAndHiddenItems() {
        let visible = makeItem(pid: 41, title: "Visible")
        let hidden = makeItem(pid: 42, title: "Hidden")
        let alreadyAlwaysHidden = makeItem(pid: 43, title: "AlwaysHidden")
        let unrecorded = makeItem(pid: 44, title: "Unrecorded")
        let snapshot = MenuBarHiddenSnapshot(
            visibleItems: [visible, unrecorded],
            hiddenItems: [hidden],
            alwaysHiddenItems: [alreadyAlwaysHidden],
            permissions: MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: true)
        )

        let candidates = MenuBarHiddenAlwaysHiddenRestorePolicy.restoreCandidates(
            snapshot: snapshot,
            recordedStableKeys: [
                visible.tag.stableKey,
                hidden.tag.stableKey,
                alreadyAlwaysHidden.tag.stableKey,
            ]
        )

        XCTAssertEqual(candidates.map(\.tag), [visible.tag, hidden.tag])
    }

    func testPermissionsRequireBothSystemGrants() {
        XCTAssertTrue(MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: true).canManageItems)
        XCTAssertFalse(MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: false).canManageItems)
        XCTAssertFalse(MenuBarHiddenPermissionsStatus(hasAccessibility: false, hasScreenRecording: true).canManageItems)
    }

    func testSourcePIDResolutionRequiresBothSystemGrants() {
        XCTAssertTrue(
            MenuBarHiddenSourcePIDResolutionPolicy.canResolve(
                permissions: MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: true)
            )
        )
        XCTAssertFalse(
            MenuBarHiddenSourcePIDResolutionPolicy.canResolve(
                permissions: MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: false)
            )
        )
        XCTAssertFalse(
            MenuBarHiddenSourcePIDResolutionPolicy.canResolve(
                permissions: MenuBarHiddenPermissionsStatus(hasAccessibility: false, hasScreenRecording: true)
            )
        )
    }

    func testRunningApplicationPolicyDropsDuplicateProcessIdentifiers() {
        struct RunningApp {
            let pid: pid_t
            let name: String
        }

        let apps = [
            RunningApp(pid: 42, name: "first"),
            RunningApp(pid: 43, name: "middle"),
            RunningApp(pid: 42, name: "duplicate"),
        ]

        let unique = MenuBarHiddenRunningApplicationPolicy.uniqueByProcessIdentifier(
            apps,
            processIdentifier: \.pid
        )

        XCTAssertEqual(unique.map(\.pid), [42, 43])
        XCTAssertEqual(unique.map(\.name), ["first", "middle"])
    }

    private func makeItem(
        pid: pid_t,
        title: String,
        bounds: CGRect = CGRect(x: 120, y: 0, width: 20, height: 20)
    ) -> MenuBarItem {
        makeItem(
            tag: MenuBarItemTag(namespace: "\(pid)", title: title, windowID: nil, instanceIndex: 0),
            pid: pid,
            title: title,
            bounds: bounds
        )
    }

    private func makeItem(namespace: String, title: String) -> MenuBarItem {
        makeItem(
            tag: MenuBarItemTag(namespace: namespace, title: title, windowID: nil, instanceIndex: 0),
            pid: 42,
            title: title,
            bounds: CGRect(x: 120, y: 0, width: 20, height: 20)
        )
    }

    private func makeItem(tag: MenuBarItemTag, pid: pid_t, title: String, bounds: CGRect) -> MenuBarItem {
        MenuBarItem(
            tag: tag,
            windowID: 0,
            ownerPID: pid,
            bounds: bounds,
            title: title,
            isOnScreen: bounds.minX >= 0
        )
    }
}
