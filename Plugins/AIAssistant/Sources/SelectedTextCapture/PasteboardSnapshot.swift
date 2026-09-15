import AppKit
import Foundation

@MainActor
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let capturedItems = (pasteboard.pasteboardItems ?? []).map { item in
            var capturedTypes: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                capturedTypes[type] = data
            }
            return capturedTypes
        }

        return PasteboardSnapshot(items: capturedItems)
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }

        var didRestoreAllData = true
        let restoredItems = items.map { capturedTypes in
            let item = NSPasteboardItem()
            for (type, data) in capturedTypes {
                if !item.setData(data, forType: type) {
                    didRestoreAllData = false
                }
            }
            return item
        }
        return didRestoreAllData && pasteboard.writeObjects(restoredItems)
    }
}
