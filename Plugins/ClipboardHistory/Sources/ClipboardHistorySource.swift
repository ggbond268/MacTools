import Foundation
import MacToolsPluginKit

enum ClipboardHistorySource: Codable, Equatable, Sendable {
    case application(ClipboardSourceApplication)
    case universalClipboard
    case unknown

    init(application: ClipboardSourceApplication?) {
        self = application.map(Self.application) ?? .unknown
    }

    var application: ClipboardSourceApplication? {
        if case let .application(application) = self { return application }
        return nil
    }

    // Application sources keep the existing storage representation for compatibility.
    var storageOverride: Self? {
        self == .universalClipboard ? self : nil
    }

    func displayName(localization: PluginLocalization, detailed: Bool = false) -> String {
        switch self {
        case let .application(application): return application.name
        case .universalClipboard:
            return detailed
                ? localization.string("source.universalClipboard", defaultValue: "Universal Clipboard")
                : localization.string("source.otherDevice", defaultValue: "Other Device")
        case .unknown: return localization.string("common.unknownSource", defaultValue: "Unknown Source")
        }
    }
}
