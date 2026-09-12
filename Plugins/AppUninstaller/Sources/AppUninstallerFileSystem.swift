import CryptoKit
import Darwin
import Foundation

extension UninstallFileIdentity {
    init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino; mode = value.st_mode
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
}

/// Narrow read-only primitives. Every open rejects symlink ancestors, network volumes, and special files.
/// Kept plugin-private until another storage plugin can adopt this contract without widening authority.
struct UninstallFileSystem: Sendable {
    var maximumEntries = 100_000
    var maximumDepth = 64
    var maximumSeconds: TimeInterval = 20

    static func physicalHome(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func open(_ path: String, directory: Bool = false) throws -> Int32 {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else {
            throw AppUninstallerError.unsafePath
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw AppUninstallerError.io(errno) }
        do {
            try validate(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validate(_ descriptor: Int32) throws {
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw AppUninstallerError.unsafePath
        }
        let identity = try identity(descriptor)
        guard identity.isDirectory || identity.isRegular else { throw AppUninstallerError.unsafePath }
    }

    func identity(_ descriptor: Int32) throws -> UninstallFileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw AppUninstallerError.io(errno) }
        return UninstallFileIdentity(value)
    }

    func identity(at path: String) throws -> UninstallFileIdentity {
        let descriptor = try open(path)
        defer { close(descriptor) }
        return try identity(descriptor)
    }

    func read(_ path: String, maximumBytes: Int = 1_048_576) throws -> Data {
        let descriptor = try open(path)
        defer { close(descriptor) }
        let before = try identity(descriptor)
        guard before.isRegular, before.size >= 0, before.size <= maximumBytes else { throw AppUninstallerError.incomplete }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw AppUninstallerError.io(errno) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw AppUninstallerError.incomplete }
        }
        guard try identity(descriptor) == before else { throw AppUninstallerError.changed }
        return data
    }

    func plist(_ path: String) throws -> [String: Any] {
        let data = try read(path)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppUninstallerError.incomplete
        }
        return value
    }

    func children(_ path: String, limit: Int = 20_000) throws -> [String] {
        let descriptor = try open(path, directory: true)
        defer { close(descriptor) }
        return try children(descriptor, limit: limit)
    }

    private func children(_ descriptor: Int32, limit: Int, deadline: Date? = nil) throws -> [String] {
        // A new open file description avoids changing the caller's directory offset.
        let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard duplicate >= 0 else { throw AppUninstallerError.io(errno) }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw AppUninstallerError.io(errno) }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            if let deadline, Date() >= deadline { throw AppUninstallerError.incomplete }
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw AppUninstallerError.io(errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw AppUninstallerError.incomplete }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= limit else { throw AppUninstallerError.incomplete }
        }
        return names.sorted()
    }

    func tree(_ path: String) throws -> UninstallTreeSnapshot {
        let descriptor = try open(path)
        defer { close(descriptor) }
        let root = try identity(descriptor)
        var hasher = SHA256()
        var entries = 0
        var bytes: Int64 = 0
        var counted = Set<String>()
        let started = Date()
        func visit(_ fd: Int32, relative: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= maximumDepth, Date().timeIntervalSince(started) <= maximumSeconds else {
                throw AppUninstallerError.incomplete
            }
            let before = try identity(fd)
            var status = stat()
            guard fstat(fd, &status) == 0 else { throw AppUninstallerError.io(errno) }
            try record(status, relative: relative)
            if before.isDirectory {
                for name in try children(fd, limit: maximumEntries, deadline: started.addingTimeInterval(maximumSeconds)) {
                    var child = stat()
                    guard fstatat(fd, name, &child, AT_SYMLINK_NOFOLLOW) == 0 else { throw AppUninstallerError.io(errno) }
                    guard UInt64(UInt32(bitPattern: child.st_dev)) == root.device else { throw AppUninstallerError.unsafePath }
                    let childRelative = relative + "/" + name
                    if child.st_mode & UInt16(S_IFMT) == UInt16(S_IFLNK) {
                        try record(child, relative: childRelative)
                        continue
                    }
                    let childFD = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard childFD >= 0 else { throw AppUninstallerError.io(errno) }
                    defer { close(childFD) }
                    try validate(childFD)
                    guard try identity(childFD) == UninstallFileIdentity(child) else { throw AppUninstallerError.changed }
                    try visit(childFD, relative: childRelative, depth: depth + 1)
                }
            }
            guard try identity(fd) == before else { throw AppUninstallerError.changed }
        }
        func record(_ status: stat, relative: String) throws {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(started) <= maximumSeconds else { throw AppUninstallerError.incomplete }
            entries += 1
            guard entries <= maximumEntries else { throw AppUninstallerError.incomplete }
            let identity = UninstallFileIdentity(status)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // Moving the root into a private stage changes its ctime, but not its contents.
            // Descendant ctimes remain part of the digest; complete identities are still checked before staging.
            let digestIdentity = relative.isEmpty ? UninstallFileIdentity(device: identity.device, inode: identity.inode,
                mode: identity.mode, size: identity.size, modifiedSeconds: identity.modifiedSeconds,
                modifiedNanoseconds: identity.modifiedNanoseconds, changedSeconds: 0, changedNanoseconds: 0) : identity
            let encoded = try encoder.encode(digestIdentity)
            hasher.update(data: Data(relative.utf8)); hasher.update(data: Data([0])); hasher.update(data: encoded)
            let key = "\(identity.device):\(identity.inode)"
            if counted.insert(key).inserted {
                let blocks = max(0, Int64(status.st_blocks))
                let (allocated, overflow) = blocks.multipliedReportingOverflow(by: 512)
                let (sum, sumOverflow) = bytes.addingReportingOverflow(allocated)
                guard !overflow, !sumOverflow else { throw AppUninstallerError.incomplete }
                bytes = sum
            }
        }
        try visit(descriptor, relative: "", depth: 0)
        guard try identity(at: path) == root else { throw AppUninstallerError.changed }
        return UninstallTreeSnapshot(identity: root, digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(), allocatedBytes: bytes, entryCount: entries)
    }

    func isMissingCandidate(_ path: String, error: Error) -> Bool {
        guard Self.isAbsent(error) else { return false }
        do { _ = try identity(at: path); return false }
        catch { return Self.isAbsent(error) }
    }

    static func isAbsent(_ error: Error) -> Bool {
        if case AppUninstallerError.io(ENOENT) = error { return true }
        return false
    }
}
