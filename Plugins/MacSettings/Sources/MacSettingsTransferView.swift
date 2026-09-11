import SwiftUI
import UniformTypeIdentifiers

enum MacSettingsProfileFilename {
    static func exportName(for profileName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
            .union(.controlCharacters)
        let components = profileName.components(separatedBy: invalidCharacters)
        let base = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? "Mac Settings" : base).mactoolsprofile"
    }
}

struct MacSettingsProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.macToolsSettingsProfile, .json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        exportedFileWrapper()
    }

    func exportedFileWrapper() -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
