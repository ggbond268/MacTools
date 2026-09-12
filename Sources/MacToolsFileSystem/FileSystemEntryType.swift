import Foundation

public enum FileSystemEntryType: Equatable, Sendable {
    case directory, regularFile, symlink, other
}
