// Synthetic model-only measurements. Never reads the system clipboard or the
// user's database. Build the plugin with ENABLE_TESTABILITY=YES.

import Foundation
import Combine
@testable import ClipboardHistoryPlugin

func ms(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

for count in [500, 5_000, 50_000] {
    let clips = (0..<count).map { index in
        ClipboardHistoryItem(id: UUID(), text: "MT88 tripod example note \(index)",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(count - index)),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
    let model = ClipboardHistoryPanelModel()
    var publications = 0
    let subscription = model.objectWillChange.sink { publications += 1 }
    var start = ContinuousClock.now
    model.prepareForPresentation(items: clips)
    let prepare = ms(ContinuousClock.now - start)
    await model.waitForSearchForTesting()
    let firstPage = ms(ContinuousClock.now - start)
    start = .now
    model.prepareForPresentation(items: clips)
    let reopen = ms(ContinuousClock.now - start)
    await model.waitForSearchForTesting()
    var updated = clips
    updated[0].lastUsedAt = Date(timeIntervalSince1970: 100_000)
    publications = 0
    start = .now
    model.updateItems(updated)
    let metadataSync = ms(ContinuousClock.now - start)
    await model.waitForSearchForTesting()
    let metadataFull = ms(ContinuousClock.now - start)
    let metadataPublications = publications
    publications = 0
    start = .now
    for _ in 0..<100 { _ = model.canEnterMultiSelection }
    let countRead = ms(ContinuousClock.now - start) / 100
    model.setMultiSelectionEnabled(true)
    start = .now
    for _ in 0..<100 {
        for clip in clips.prefix(10) { model.toggleMultiSelection(for: clip.id) }
    }
    let checkbox = ms(ContinuousClock.now - start) / 1000
    start = .now
    model.query = "88"
    await model.waitForSearchForTesting()
    let substring = ms(ContinuousClock.now - start)
    var settings = ClipboardHistorySettings.defaults
    settings.maximumItemCount = ClipboardHistorySettings.noItemCountLimit
    settings.maximumTotalPayloadByteCount = Int.max
    settings.expiration = .never
    start = .now
    _ = ClipboardRetentionPolicy.prune(updated, settings: settings)
    let retention = ms(ContinuousClock.now - start)
    print("n=\(count) prepare=\(prepare) firstPage=\(firstPage) reopen=\(reopen) metadataSync=\(metadataSync) metadataFull=\(metadataFull) metadataPublications=\(metadataPublications) eligibilityRead=\(countRead) checkboxModel=\(checkbox) search88IncludingDebounce=\(substring) retention=\(retention) [ms]")
    if CommandLine.arguments.contains("--targeted") {
        updated[1].lastUsedAt = Date(timeIntervalSince1970: 100_001)
        publications = 0
        start = .now
        model.updateItems(updated, changedIDs: [updated[1].id])
        let targeted = ms(ContinuousClock.now - start)
        precondition(!model.isSearching)
        print("n=\(count) targetedMetadata=\(targeted) publications=\(publications) [ms]")
    }
    withExtendedLifetime(subscription) {}
}
