import CommonCrypto
import CryptoKit
import Foundation

struct ClipboardBackupScope: Codable, Equatable, Sendable {
    var history = false
    var saved = true
    var snippets = true
    var isEmpty: Bool { !history && !saved && !snippets }
    var isComplete: Bool { history && saved && snippets }
}

struct ClipboardBackupManifest: Codable, Equatable, Sendable {
    var version = 1
    var createdAt = Date()
    var scope: ClipboardBackupScope
    var records = 0
    var history = 0
    var saved = 0
    var snippets = 0
    var payloadBytes: Int64 = 0
    var digest = Data()
}

enum ClipboardBackupError: Error, LocalizedError {
    case invalidArchive, unsupportedVersion, invalidPassword, passwordTooLong, limitExceeded, storage, changedSincePreview

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "备份无效、已损坏或密码错误。当前数据未更改。"
        case .unsupportedVersion: "此备份版本暂不受支持。"
        case .invalidPassword: "请使用至少 12 个字符的备份密码。"
        case .passwordTooLong: "密码过长，请缩短后重试。"
        case .limitExceeded: "备份超过安全上限或当前单项大小限制。"
        case .storage: "无法读写备份。请检查可用磁盘空间和文件权限。"
        case .changedSincePreview: "本机剪贴板数据已更改。请重新预览备份。"
        }
    }
}

/// One bounded plaintext record at a time; no device key is part of the wire model.
enum ClipboardBackupArchive {
    static let magic = Data("MTCLPBK1".utf8)
    static let iterations: UInt32 = 600_000
    static let maximumFrameBytes = 160 * 1_024 * 1_024
    static let maximumRecords = 1_000_000
    static let maximumArchiveBytes: UInt64 = 100 * 1_024 * 1_024 * 1_024

    static func integer(_ value: UInt64, bytes: Int = 8) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    static func number(_ data: Data) -> UInt64 {
        data.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    static func derive(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        guard (600_000...2_000_000).contains(rounds) else { throw ClipboardBackupError.limitExceeded }
        let passwordBytes = Array(password.utf8)
        guard !passwordBytes.isEmpty else { throw ClipboardBackupError.invalidPassword }
        guard passwordBytes.count <= 1_024 else { throw ClipboardBackupError.passwordTooLong }
        try Task.checkCancellation()
        var output = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                    passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                                    saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &output, output.count)
            }
        }
        defer { _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard status == kCCSuccess else { throw ClipboardBackupError.invalidArchive }
        try Task.checkCancellation()
        return SymmetricKey(data: output)
    }

    static func read(_ handle: FileHandle, count: Int) throws -> Data {
        guard count >= 0, count <= maximumFrameBytes else { throw ClipboardBackupError.limitExceeded }
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            guard let part = try handle.read(upToCount: min(count - data.count, 1_024 * 1_024)), !part.isEmpty else {
                throw ClipboardBackupError.invalidArchive
            }
            data.append(part)
        }
        return data
    }

    final class Writer {
        private let handle: FileHandle
        private let key = SymmetricKey(size: .bits256)
        private let context: Data
        private var sequence: UInt64 = 0
        private var bytesWritten: UInt64 = 0
        private var digest = SHA256()

        init(url: URL, password: String) throws {
            guard password.count >= 12 else { throw ClipboardBackupError.invalidPassword }
            let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let header = magic + integer(1, bytes: 4) + integer(UInt64(iterations), bytes: 4) + salt
            let wrappingKey = try derive(password: password, salt: salt, rounds: iterations)
            let wrapped = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrappingKey, authenticating: header)
            guard let wrappedBytes = wrapped.combined else { throw ClipboardBackupError.invalidArchive }
            let completeHeader = header + wrappedBytes
            context = Data(SHA256.hash(data: completeHeader))
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ClipboardBackupError.storage
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: completeHeader)
        }

        deinit { try? handle.close() }

        func append(_ record: ClipboardBackupRecord) throws {
            guard sequence < maximumRecords else { throw ClipboardBackupError.limitExceeded }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(record)
            digest.update(data: data)
            try frame(Data([1]) + data)
        }

        func finish(_ manifest: ClipboardBackupManifest) throws {
            var manifest = manifest
            manifest.digest = Data(digest.finalize())
            try frame(Data([2]) + JSONEncoder().encode(manifest))
            try handle.synchronize()
            try handle.close()
        }

        private func frame(_ data: Data) throws {
            try Task.checkCancellation()
            guard data.count + 28 <= maximumFrameBytes else { throw ClipboardBackupError.limitExceeded }
            let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + integer(sequence))
            let sealed = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: context + integer(sequence))
            guard let combined = sealed.combined else { throw ClipboardBackupError.invalidArchive }
            bytesWritten += UInt64(combined.count + 4)
            guard bytesWritten <= maximumArchiveBytes else { throw ClipboardBackupError.limitExceeded }
            try handle.write(contentsOf: integer(UInt64(combined.count), bytes: 4))
            // Bound cancellation latency even for a maximum-sized item.
            for offset in stride(from: 0, to: combined.count, by: 1_024 * 1_024) {
                try Task.checkCancellation()
                try handle.write(contentsOf: combined[offset..<min(offset + 1_024 * 1_024, combined.count)])
            }
            sequence += 1
        }
    }

    static func read(url: URL, password: String, maximumItemBytes: Int = 64 * 1_024 * 1_024, record: (ClipboardBackupRecord) throws -> Void) throws -> ClipboardBackupManifest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= maximumArchiveBytes else { throw ClipboardBackupError.limitExceeded }
        try handle.seek(toOffset: 0)
        let header = try read(handle, count: 48)
        guard header.prefix(8) == magic else { throw ClipboardBackupError.invalidArchive }
        guard number(header.subdata(in: 8..<12)) == 1 else { throw ClipboardBackupError.unsupportedVersion }
        let rounds = UInt32(number(header.subdata(in: 12..<16)))
        let wrappingKey = try derive(password: password, salt: header.subdata(in: 16..<48), rounds: rounds)
        let wrapped = try read(handle, count: 60)
        let keyData: Data
        do { keyData = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: wrappingKey, authenticating: header) }
        catch { throw ClipboardBackupError.invalidArchive }
        guard keyData.count == 32 else { throw ClipboardBackupError.invalidArchive }
        let key = SymmetricKey(data: keyData)
        let context = Data(SHA256.hash(data: header + wrapped))
        var digest = SHA256()
        for sequence in 0...maximumRecords {
            let terminal = try autoreleasepool { () throws -> ClipboardBackupManifest? in
                try Task.checkCancellation()
                let length = number(try read(handle, count: 4))
                guard length >= 29, length <= min(maximumFrameBytes, maximumItemBytes * 2 + 3 * 1_024 * 1_024) else { throw ClipboardBackupError.limitExceeded }
                let combined = try read(handle, count: Int(length))
                let plain: Data
                do {
                    plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key,
                                             authenticating: context + integer(UInt64(sequence)))
                } catch { throw ClipboardBackupError.invalidArchive }
                switch plain.first {
                case 1:
                    guard sequence < maximumRecords else { throw ClipboardBackupError.limitExceeded }
                    let data = Data(plain.dropFirst())
                    digest.update(data: data)
                    let decoded: ClipboardBackupRecord
                    do { decoded = try PropertyListDecoder().decode(ClipboardBackupRecord.self, from: data) }
                    catch { throw ClipboardBackupError.invalidArchive }
                    try record(decoded)
                    return nil
                case 2:
                    let manifest: ClipboardBackupManifest
                    do { manifest = try JSONDecoder().decode(ClipboardBackupManifest.self, from: Data(plain.dropFirst())) }
                    catch { throw ClipboardBackupError.invalidArchive }
                    guard manifest.version == 1, manifest.records == sequence, !manifest.scope.isEmpty,
                          manifest.digest == Data(digest.finalize()), try handle.offset() == size else {
                        throw ClipboardBackupError.invalidArchive
                    }
                    return manifest
                default: throw ClipboardBackupError.invalidArchive
                }
            }
            if let terminal { return terminal }
        }
        throw ClipboardBackupError.limitExceeded
    }
}
