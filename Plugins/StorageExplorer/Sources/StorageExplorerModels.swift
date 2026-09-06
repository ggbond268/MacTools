import Foundation
import SwiftUI

// MARK: - Inode Identity for Hard Link Deduplication

public struct StorageFileInode: Hashable, Sendable {
    public let device: dev_t
    public let inode: ino_t

    public init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }
}

// MARK: - Storage Item

public struct StorageItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let url: URL
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public var size: Int64
    public var allocatedSize: Int64
    public let modificationDate: Date?
    public var childCount: Int
    public var children: [StorageItem]
    public var isAccessDenied: Bool

    public init(
        id: String? = nil,
        name: String,
        path: String,
        url: URL,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        size: Int64 = 0,
        allocatedSize: Int64 = 0,
        modificationDate: Date? = nil,
        childCount: Int = 0,
        children: [StorageItem] = [],
        isAccessDenied: Bool = false
    ) {
        self.id = id ?? path
        self.name = name
        self.path = path
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.size = size
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.childCount = childCount
        self.children = children
        self.isAccessDenied = isAccessDenied
    }

    public var fileExtension: String {
        url.pathExtension.lowercased()
    }

    public var iconSystemName: String {
        if isDirectory {
            if isPackage {
                return "shippingbox.fill"
            }
            return "folder.fill"
        }

        switch fileExtension {
        case "dmg", "iso", "pkg":
            return "opticaldisc"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return "archivebox.fill"
        case "mov", "mp4", "mkv", "avi", "webm":
            return "film.fill"
        case "mp3", "m4a", "flac", "wav", "aac":
            return "music.note"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw":
            return "photo.fill"
        case "swift", "py", "js", "ts", "rs", "c", "cpp", "h", "java", "go", "rb", "sh", "json", "yml", "yaml", "toml":
            return "curlybraces"
        case "pdf":
            return "doc.richtext.fill"
        case "app":
            return "app.dashed"
        default:
            return "doc.fill"
        }
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public static func == (lhs: StorageItem, rhs: StorageItem) -> Bool {
        lhs.path == rhs.path && lhs.size == rhs.size && lhs.childCount == rhs.childCount
    }
}

// MARK: - Scan Progress and State

public struct StorageExplorerScanProgress: Sendable, Equatable {
    public var filesScanned: Int
    public var bytesScanned: Int64
    public var currentPath: String

    public init(filesScanned: Int = 0, bytesScanned: Int64 = 0, currentPath: String = "") {
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
    }
}

public enum StorageExplorerScanState: Sendable, Equatable {
    case idle
    case scanning(StorageExplorerScanProgress)
    case completed
    case failed(String)
    case cancelled
}
