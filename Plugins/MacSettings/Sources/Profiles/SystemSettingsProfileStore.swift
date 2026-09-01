import Foundation
import MacToolsPluginKit

enum SystemSettingsProfileFileReader {
    static func read(
        from url: URL,
        maximumFileSize: Int
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false else {
                throw SystemSettingsProfileCodecError.malformedFile
            }
            if let fileSize = values.fileSize, fileSize > maximumFileSize {
                throw SystemSettingsProfileCodecError.fileTooLarge
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
            guard data.count <= maximumFileSize else {
                throw SystemSettingsProfileCodecError.fileTooLarge
            }
            return data
        }.value
    }
}

@MainActor
protocol SystemSettingsProfileStoring: AnyObject {
    func load() -> [SystemSettingsProfile]
    @discardableResult
    func save(_ profile: SystemSettingsProfile) -> Bool
    @discardableResult
    func remove(id: UUID) -> Bool
    @discardableResult
    func replaceAll(_ profiles: [SystemSettingsProfile]) -> Bool
}

@MainActor
final class SystemSettingsProfileStore: SystemSettingsProfileStoring {
    private enum Key {
        static let profiles = "settings-profiles-v1"
    }

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [SystemSettingsProfile] {
        guard let data = storage.data(forKey: Key.profiles),
              data.count <= SystemSettingsProfileCodec.maximumFileSize,
              let profiles = try? decoder.decode([SystemSettingsProfile].self, from: data) else {
            return []
        }
        return profiles
            .filter { $0.formatVersion == SystemSettingsProfile.currentFormatVersion }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @discardableResult
    func save(_ profile: SystemSettingsProfile) -> Bool {
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        return replaceAll(profiles)
    }

    func replaceAll(_ profiles: [SystemSettingsProfile]) -> Bool {
        guard profiles.count <= 100,
              Set(profiles.map(\.id)).count == profiles.count,
              let data = try? encoder.encode(profiles.sorted { $0.modifiedAt > $1.modifiedAt }),
              data.count <= SystemSettingsProfileCodec.maximumFileSize else {
            return false
        }
        let previous = storage.data(forKey: Key.profiles)
        storage.set(data, forKey: Key.profiles)
        guard storage.data(forKey: Key.profiles) == data else {
            if let previous { storage.set(previous, forKey: Key.profiles) }
            else { storage.removeObject(forKey: Key.profiles) }
            return false
        }
        return true
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        let updated = load().filter { $0.id != id }
        return replaceAll(updated)
    }
}

@MainActor
final class InMemorySystemSettingsProfileStore: SystemSettingsProfileStoring {
    private(set) var profiles: [SystemSettingsProfile]

    init(profiles: [SystemSettingsProfile] = []) {
        self.profiles = profiles
    }

    func load() -> [SystemSettingsProfile] {
        profiles.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func save(_ profile: SystemSettingsProfile) -> Bool {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        return true
    }

    func remove(id: UUID) -> Bool {
        profiles.removeAll { $0.id == id }
        return true
    }

    func replaceAll(_ profiles: [SystemSettingsProfile]) -> Bool {
        guard profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count else { return false }
        self.profiles = profiles
        return true
    }
}
