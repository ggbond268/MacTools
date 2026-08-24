import Foundation

enum ClipboardHistoryExportNaming {
    static let maximumBaseNameCharacterCount = 120

    static func capturedTimestamp(_ date: Date, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    static func sanitizedBaseName(_ candidate: String) -> String {
        let scalars = candidate.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            if CharacterSet(charactersIn: "/:").contains(scalar) { return "-" }
            return Character(String(scalar))
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(collapsed.prefix(maximumBaseNameCharacterCount))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return bounded.isEmpty ? "Clipboard Item" : bounded
    }

    static func fileName(baseName: String, extension fileExtension: String, index: Int? = nil) -> String {
        let suffix = index.map { " \($0)" } ?? ""
        return "\(sanitizedBaseName(baseName))\(suffix).\(fileExtension)"
    }

    static func availableURL(
        in directory: URL,
        preferredFileName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let preferred = directory.appendingPathComponent(preferredFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }

        let extensionValue = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        let index = try firstAvailableCollisionIndex { index in
            let candidateName = extensionValue.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionValue)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            return fileManager.fileExists(atPath: candidate.path)
        }
        let candidateName = extensionValue.isEmpty
            ? "\(stem) \(index)"
            : "\(stem) \(index).\(extensionValue)"
        return directory.appendingPathComponent(candidateName, isDirectory: false)
    }

    static func availableDirectoryURL(
        in directory: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let preferred = directory.appendingPathComponent(preferredName, isDirectory: true)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let index = try firstAvailableCollisionIndex { index in
            fileManager.fileExists(
                atPath: directory.appendingPathComponent(
                    "\(preferredName) \(index)",
                    isDirectory: true
                ).path
            )
        }
        return directory.appendingPathComponent("\(preferredName) \(index)", isDirectory: true)
    }

    static func firstAvailableCollisionIndex(
        isOccupied: (Int) -> Bool
    ) throws -> Int {
        var index = 2
        while isOccupied(index) {
            guard index < Int.max else { throw ClipboardExportError.unsafeDestination }
            index += 1
        }
        return index
    }

    static func safeRelativePath(_ path: String) -> String? {
        let components = NSString(string: path).pathComponents
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !components.contains(".."),
              components.contains(where: { $0 != "." }) else {
            return nil
        }
        return path
    }
}
