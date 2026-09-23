import CoreGraphics
import Foundation
import MacToolsPluginKit

@MainActor
protocol DisplayDisableCoordinating: AnyObject {
    var snapshot: DisplayDisableSnapshot { get }
    /// Called when the snapshot changes outside a caller's request, such as a lid-open restore.
    var onSnapshotChange: (() -> Void)? { get set }

    func refreshSnapshot()
    func disableDisplay(_ displayID: CGDirectDisplayID) async
    func restoreDisplay(_ displayID: CGDirectDisplayID)
    /// Restores every display MacTools switched off, on deactivation and at startup. Displays
    /// switched off by anything else are never touched.
    func restoreAllDisplays()
    func reconcileTopology()
    func stopObserving()
}

@MainActor
final class DisplayDisableCoordinator: DisplayDisableCoordinating {
    private enum RestoreResult {
        case restored
        case lidClosed
        case failed
    }

    private let service: any DisplayDisableServicing
    private let store: any DisplayDisableStateStoring
    private let lidObserver: any DisplayLidObserving
    private let localization: PluginLocalization
    private let verificationSettleDelay: Duration
    private let presentationPreparation: @MainActor @Sendable () -> Void

    private(set) var snapshot: DisplayDisableSnapshot
    var onSnapshotChange: (() -> Void)?
    private var message: String?
    /// The display whose switch-off is still being verified. Reconciles that run meanwhile must
    /// not drop or restore its record before the transaction has settled.
    private var pendingDisableID: CGDirectDisplayID?

    init(
        service: any DisplayDisableServicing,
        store: any DisplayDisableStateStoring,
        lidObserver: any DisplayLidObserving,
        localization: PluginLocalization = DisplayBrightnessLocalization.fallback,
        verificationSettleDelay: Duration = .milliseconds(800),
        presentationPreparation: @escaping @MainActor @Sendable () -> Void = {
            PluginPresentationSafety.prepareForWindowOrdering()
        }
    ) {
        self.service = service
        self.store = store
        self.lidObserver = lidObserver
        self.localization = localization
        self.verificationSettleDelay = verificationSettleDelay
        self.presentationPreparation = presentationPreparation
        self.snapshot = DisplayDisableSnapshot(isSupported: false, entries: [], message: nil)
        refreshSnapshot()
    }

    func refreshSnapshot() {
        snapshot = makeSnapshot(displays: service.listDisplays(), records: store.records)
    }

    func disableDisplay(_ displayID: CGDirectDisplayID) async {
        let displays = service.listDisplays()
        guard let target = displays.first(where: { $0.id == displayID && $0.isDrawable }) else {
            finish(message: string("displayDisable.message.displayDisconnected", "显示器已断开连接"))
            return
        }

        let drawable = displays.filter(\.isDrawable)
        if let reason = disableBlockReason(for: target, drawable: drawable) {
            finish(message: reason)
            return
        }

        let survivors = drawable.filter { $0.id != target.id }
        var records = store.records
        records.removeAll { $0.matchesTarget(target) }
        records.append(DisplayDisableRecord(
            createdAt: Date(),
            displayID: target.id,
            name: target.name,
            isBuiltin: target.isBuiltin,
            vendorNumber: target.vendorNumber,
            modelNumber: target.modelNumber,
            serialNumber: target.serialNumber,
            survivorIdentities: survivors.map(survivorIdentity(for:))
        ))
        store.records = records
        pendingDisableID = target.id
        defer { pendingDisableID = nil }

        do {
            presentationPreparation()
            try service.setDisplay(target.id, enabled: false)
        } catch {
            removeRecord(displayID: target.id)
            finish(message: string("displayDisable.message.disableFailed", "关闭显示器失败"))
            return
        }
        syncLidObserver()

        guard (try? await Task.sleep(for: verificationSettleDelay)) != nil, !Task.isCancelled else {
            refreshSnapshot()
            return
        }

        let verifiedDisplays = service.listDisplays()
        if disableSucceeded(targetID: target.id, survivorIDs: Set(survivors.map(\.id)), displays: verifiedDisplays) {
            finish(message: nil)
            return
        }

        presentationPreparation()
        if (try? service.setDisplay(target.id, enabled: true)) != nil {
            removeRecord(displayID: target.id)
        }
        finish(message: string("displayDisable.message.disableFailedRestored", "关闭显示器失败，已尝试恢复"))
    }

    func restoreDisplay(_ displayID: CGDirectDisplayID) {
        var records = store.records
        guard let index = records.firstIndex(where: { $0.displayID == displayID }) else {
            refreshSnapshot()
            return
        }

        switch restore(records[index], displays: service.listDisplays()) {
        case .restored:
            records.remove(at: index)
            message = nil
        case .lidClosed:
            records[index].restoreRequested = true
            message = lidClosedMessage
        case .failed:
            message = restoreFailedMessage
        }
        store.records = records
        syncLidObserver()
        refreshSnapshot()
    }

    func restoreAllDisplays() {
        let displays = service.listDisplays()
        var remaining: [DisplayDisableRecord] = []
        var restoreFailed = false
        // Skip displays already back on, typically reverted by the window server when the
        // previous process exited, so no needless reconfiguration shuffles windows.
        let pending = store.records.filter { record in
            !displays.contains { $0.isDrawable && record.matchesTarget($0) }
        }
        for var record in pending {
            let result = restore(record, displays: displays)
            guard result != .restored else {
                continue
            }
            // Every later reconcile retries it: after the lid opens, or on the next start at
            // the latest.
            record.restoreRequested = true
            remaining.append(record)
            restoreFailed = restoreFailed || result == .failed
        }
        store.records = remaining
        if restoreFailed {
            message = restoreFailedMessage
        } else {
            message = remaining.isEmpty ? nil : lidClosedMessage
        }
        syncLidObserver()
        refreshSnapshot()
    }

    func reconcileTopology() {
        var displays = service.listDisplays()
        var records = store.records.filter { record in
            // A display that is back on, re-enabled elsewhere or reconnected, is no longer
            // ours to manage.
            record.displayID == pendingDisableID
                || !displays.contains { $0.isDrawable && record.matchesTarget($0) }
        }

        // Keep a display switched off while any display that stayed on with it remains. Restore
        // it once all of them are gone, which indicates a real disconnect. A time window is not
        // reliable: sleep/wake or resolution changes would otherwise trigger an unintended
        // restore during benign topology transitions.
        var kept: [DisplayDisableRecord] = []
        var restoredAny = false
        var restoreFailed = false
        for record in records.sorted(by: { $0.isBuiltin && !$1.isBuiltin }) {
            guard record.displayID != pendingDisableID,
                  record.restoreRequested || !survivorRemains(for: record, displays: displays)
            else {
                kept.append(record)
                continue
            }

            switch restore(record, displays: displays) {
            case .restored:
                restoredAny = true
                displays = service.listDisplays()
            case .lidClosed:
                // The lid observer retries once the lid opens.
                kept.append(record)
            case .failed:
                restoreFailed = true
                kept.append(record)
            }
        }
        records = kept

        // Never leave the Mac without a usable display: if nothing drawable remains, bring back
        // one display MacTools switched off, whatever its survivors say.
        if !restoredAny, !displays.contains(where: \.isDrawable) {
            for (index, record) in records.enumerated() where record.displayID != pendingDisableID {
                if restore(record, displays: displays) == .restored {
                    records.remove(at: index)
                    restoredAny = true
                    break
                }
            }
        }

        if restoreFailed {
            message = restoreFailedMessage
        } else if restoredAny {
            message = nil
        }
        store.records = records
        syncLidObserver()
        refreshSnapshot()
    }

    func stopObserving() {
        lidObserver.stopObserving()
    }

    private func restore(_ record: DisplayDisableRecord, displays: [DisplayDisableDisplay]) -> RestoreResult {
        // Enabling the built-in panel while the lid is closed is refused; the lid observer
        // finishes the restore once it opens.
        if record.isBuiltin, service.isLidClosed == true {
            return .lidClosed
        }

        // The stored ID first, then the same monitor under a new ID after sleep/wake.
        let candidateIDs = [record.displayID] + displays
            .filter { $0.id != record.displayID && !$0.isDrawable && record.matchesTarget($0) }
            .map(\.id)
        for displayID in candidateIDs {
            do {
                presentationPreparation()
                try service.setDisplay(displayID, enabled: true)
                return .restored
            } catch {
                continue
            }
        }
        return .failed
    }

    private func makeSnapshot(
        displays: [DisplayDisableDisplay],
        records: [DisplayDisableRecord]
    ) -> DisplayDisableSnapshot {
        let drawable = displays.filter(\.isDrawable)
        var entries = drawable.map { display in
            let reason = disableBlockReason(for: display, drawable: drawable)
            return DisplayDisableEntry(
                id: display.id,
                name: display.name,
                isBuiltin: display.isBuiltin,
                isDisabled: false,
                isDisableAllowed: reason == nil,
                unavailableReason: reason
            )
        }
        for record in records where !drawable.contains(where: record.matchesTarget) {
            entries.append(DisplayDisableEntry(
                id: record.displayID,
                name: record.name,
                isBuiltin: record.isBuiltin,
                isDisabled: true,
                isDisableAllowed: false,
                unavailableReason: nil
            ))
        }

        return DisplayDisableSnapshot(
            isSupported: service.isSupported,
            entries: entries,
            message: message
        )
    }

    private func disableBlockReason(
        for display: DisplayDisableDisplay,
        drawable: [DisplayDisableDisplay]
    ) -> String? {
        guard service.isSupported else {
            return string("displayDisable.unsupported", "当前系统不支持关闭显示器")
        }
        guard !display.isInMirrorSet else {
            return string("displayDisable.message.mirrorUnsupported", "镜像显示时暂不支持关闭显示器")
        }
        // Switching off the last drawable display would leave no screen to switch it back on.
        guard drawable.contains(where: { $0.id != display.id }) else {
            return display.isBuiltin
                ? string("displayDisable.message.needsExternalDisplay", "连接外接显示器后可关闭内建显示屏")
                : string("displayDisable.message.lastDisplay", "至少需要保留一个显示器")
        }
        return nil
    }

    private func finish(message: String?) {
        self.message = message
        syncLidObserver()
        refreshSnapshot()
    }

    private func removeRecord(displayID: CGDirectDisplayID) {
        store.records = store.records.filter { $0.displayID != displayID }
    }

    /// The lid only matters to a switched-off built-in panel, so observe it only then.
    private func syncLidObserver() {
        guard store.records.contains(where: \.isBuiltin) else {
            lidObserver.stopObserving()
            return
        }

        lidObserver.startObserving { [weak self] in
            guard let self else { return }
            self.reconcileTopology()
            self.onSnapshotChange?()
        }
    }

    private func survivorRemains(
        for record: DisplayDisableRecord,
        displays: [DisplayDisableDisplay]
    ) -> Bool {
        let onlineSurvivors = displays.filter { $0.isDrawable && !record.matchesTarget($0) }
        return record.survivorIdentities.contains { identity in
            onlineSurvivors.contains { matchesSurvivor(identity: identity, display: $0) }
        }
    }

    // Prefer EDID identity (vendor/model/serial) so a CGDirectDisplayID change after external
    // display sleep/wake is not misclassified as a disconnect. Fall back to displayID when EDID
    // data is unavailable.
    private func matchesSurvivor(
        identity: DisplaySurvivorIdentity,
        display: DisplayDisableDisplay
    ) -> Bool {
        if identity.vendorNumber != nil || identity.modelNumber != nil || identity.serialNumber != nil {
            return identity.vendorNumber == display.vendorNumber
                && identity.modelNumber == display.modelNumber
                && identity.serialNumber == display.serialNumber
        }
        return identity.id == display.id
    }

    private func survivorIdentity(for display: DisplayDisableDisplay) -> DisplaySurvivorIdentity {
        DisplaySurvivorIdentity(
            id: display.id,
            vendorNumber: display.vendorNumber,
            modelNumber: display.modelNumber,
            serialNumber: display.serialNumber
        )
    }

    private func disableSucceeded(
        targetID: CGDirectDisplayID,
        survivorIDs: Set<CGDirectDisplayID>,
        displays: [DisplayDisableDisplay]
    ) -> Bool {
        let targetIsGone = displays.first(where: { $0.id == targetID }).map { !$0.isDrawable } ?? true
        let survivorRemains = displays.contains { survivorIDs.contains($0.id) && $0.isDrawable }
        return targetIsGone && survivorRemains
    }

    private var lidClosedMessage: String {
        string("displayDisable.message.lidClosed", "打开盖子后将恢复内建显示屏")
    }

    private var restoreFailedMessage: String {
        string("displayDisable.message.restoreFailed", "恢复显示器失败")
    }

    private func string(_ key: String, _ defaultValue: String) -> String {
        localization.string(key, defaultValue: defaultValue)
    }
}
