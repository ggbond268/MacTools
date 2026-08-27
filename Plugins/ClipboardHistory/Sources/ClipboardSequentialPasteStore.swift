import Foundation
import MacToolsPluginKit

final class PluginStorageClipboardSequentialPasteStore: ClipboardSequentialPasteSessionPersisting {
    private static let storageKey = "sequential-paste-explicit-session"

    private let storage: PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: PluginStorage) {
        self.storage = storage
    }

    func loadExplicitSession() -> ClipboardSequentialPasteSession? {
        guard let data = storage.data(forKey: Self.storageKey) else { return nil }
        guard let session = try? decoder.decode(
            ClipboardSequentialPasteSession.self,
            from: data
        ), session.source == .explicitQueue, !session.isComplete else {
            storage.removeObject(forKey: Self.storageKey)
            return nil
        }
        return session
    }

    func saveExplicitSession(_ session: ClipboardSequentialPasteSession?) {
        guard let session,
              session.source == .explicitQueue,
              !session.isComplete,
              let data = try? encoder.encode(session) else {
            storage.removeObject(forKey: Self.storageKey)
            return
        }
        storage.set(data, forKey: Self.storageKey)
    }
}
