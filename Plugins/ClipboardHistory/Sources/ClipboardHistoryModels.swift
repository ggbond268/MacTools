import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ClipboardSourceApplication: Codable, Equatable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
}

struct ClipboardExcludedApplication: Codable, Equatable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

enum ClipboardExcludedApplicationDisplayName {
    static func fallbackLocalizationKey(for bundleIdentifier: String) -> String? {
        switch bundleIdentifier.lowercased() {
        case "com.apple.passwords":
            "excludedApplication.passwords"
        case "com.apple.keychainaccess":
            "excludedApplication.keychainAccess"
        default:
            nil
        }
    }

    static func resolve(
        application: ClipboardExcludedApplication,
        installedLocalizedName: String?,
        localizedFallback: (String) -> String?
    ) -> String {
        if let installedLocalizedName, !installedLocalizedName.isEmpty {
            return installedLocalizedName
        }
        guard let key = fallbackLocalizationKey(for: application.bundleIdentifier),
              let fallback = localizedFallback(key),
              !fallback.isEmpty else {
            return application.name
        }
        return fallback
    }
}

enum ClipboardRepresentationType {
    static let plainText = "public.utf8-plain-text"
    static let rtf = "public.rtf"
    static let rtfd = "com.apple.flat-rtfd"
    static let html = "public.html"
    static let png = "public.png"
    static let tiff = "public.tiff"
    static let pdf = "com.adobe.pdf"
    static let fileURL = "public.file-url"
    static let url = "public.url"
    static let color = "com.apple.cocoa.pasteboard.color"
    static let sound = "com.apple.cocoa.pasteboard.sound"

    private static let exactSupportedTypes: Set<String> = [
        plainText,
        rtf,
        rtfd,
        html,
        png,
        tiff,
        pdf,
        fileURL,
        url,
        color,
        sound,
    ]

    static func isSupported(_ typeIdentifier: String) -> Bool {
        if exactSupportedTypes.contains(typeIdentifier) {
            return true
        }
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .image)
            || type.conforms(to: .audio)
            || type.conforms(to: .movie)
    }

    static func isImage(_ typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .image)
    }

    static func isMedia(_ typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }
}

struct ClipboardStoredRepresentation: Codable, Equatable, Sendable {
    let typeIdentifier: String
    let data: Data
}

struct ClipboardStoredPasteboardItem: Codable, Equatable, Sendable {
    let representations: [ClipboardStoredRepresentation]
}

enum ClipboardHistoryContentKind: String, Codable, Equatable, Sendable {
    case plainText
    case richText
    case image
    case pdf
    case files
    case link
    case color
    case media
}

enum ClipboardFileContentKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case pdf
    case image
    case audio
    case video

    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) {
            self = .video
        } else if type.conforms(to: .audio) {
            self = .audio
        } else {
            return nil
        }
    }

    var contentKind: ClipboardHistoryContentKind {
        switch self {
        case .pdf: .pdf
        case .image: .image
        case .audio, .video: .media
        }
    }
}

struct ClipboardHistoryPayload: Codable, Equatable, Sendable {
    let pasteboardItems: [ClipboardStoredPasteboardItem]

    init(pasteboardItems: [ClipboardStoredPasteboardItem]) {
        self.pasteboardItems = pasteboardItems.filter { !$0.representations.isEmpty }
    }

    static func plainText(_ text: String) -> Self {
        Self(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data(text.utf8)
                ),
            ]),
        ])
    }

    var representations: [ClipboardStoredRepresentation] {
        pasteboardItems.flatMap(\.representations)
    }

    var byteCount: Int {
        representations.reduce(0) { $0 + $1.data.count }
    }

    var plainTexts: [String] {
        representations
            .filter { $0.typeIdentifier == ClipboardRepresentationType.plainText }
            .compactMap { String(data: $0.data, encoding: .utf8) }
    }

    var plainText: String? { plainTexts.first }

    var fileURLs: [URL] {
        representations.compactMap { representation in
            guard representation.typeIdentifier == ClipboardRepresentationType.fileURL,
                  let value = String(data: representation.data, encoding: .utf8) else {
                return nil
            }
            return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var fileContentKinds: Set<ClipboardFileContentKind> {
        Set(fileURLs.compactMap(ClipboardFileContentKind.init(url:)))
    }

    /// Types used for discovery and filtering. A Finder file remains a native
    /// file-reference payload while also appearing in its semantic type filter.
    var filterContentKinds: Set<ClipboardHistoryContentKind> {
        let types = representations.map(\.typeIdentifier)
        var kinds: Set<ClipboardHistoryContentKind> = [kind]

        if !fileURLs.isEmpty {
            kinds.insert(.files)
            kinds.formUnion(fileContentKinds.map(\.contentKind))
        }
        if types.contains(where: ClipboardRepresentationType.isImage) {
            kinds.insert(.image)
        }
        if types.contains(ClipboardRepresentationType.pdf) {
            kinds.insert(.pdf)
        }
        if types.contains(ClipboardRepresentationType.rtf)
            || types.contains(ClipboardRepresentationType.rtfd)
            || types.contains(ClipboardRepresentationType.html) {
            kinds.insert(.richText)
        }
        if types.contains(where: ClipboardRepresentationType.isMedia)
            || types.contains(ClipboardRepresentationType.sound) {
            kinds.insert(.media)
        }
        if types.contains(ClipboardRepresentationType.color) {
            kinds.insert(.color)
        }
        if types.contains(ClipboardRepresentationType.url) {
            kinds.insert(.link)
        }
        if types.contains(ClipboardRepresentationType.plainText) {
            kinds.insert(.plainText)
        }
        return kinds
    }

    var hasUnavailableFileReferences: Bool {
        fileURLs.contains { !FileManager.default.fileExists(atPath: $0.path) }
    }

    var searchableText: String {
        let textValues = plainTexts.filter { !$0.isEmpty }
        if !textValues.isEmpty {
            return textValues.joined(separator: "\n")
        }
        let fileNames = fileURLs.map(\.lastPathComponent).filter { !$0.isEmpty }
        return fileNames.joined(separator: "\n")
    }

    var kind: ClipboardHistoryContentKind {
        let types = representations.map(\.typeIdentifier)
        if types.contains(ClipboardRepresentationType.fileURL) {
            return .files
        }
        if types.contains(where: ClipboardRepresentationType.isImage) {
            return .image
        }
        if types.contains(ClipboardRepresentationType.pdf) {
            return .pdf
        }
        if types.contains(ClipboardRepresentationType.rtf)
            || types.contains(ClipboardRepresentationType.rtfd)
            || types.contains(ClipboardRepresentationType.html) {
            return .richText
        }
        if types.contains(where: ClipboardRepresentationType.isMedia)
            || types.contains(ClipboardRepresentationType.sound) {
            return .media
        }
        if types.contains(ClipboardRepresentationType.color) {
            return .color
        }
        if types.contains(ClipboardRepresentationType.url) {
            return .link
        }
        return .plainText
    }
}

struct ClipboardHistorySearchIndex: Equatable, Sendable {
    let normalizedText: String
    let tokens: [String]
}

enum ClipboardHistoryPayloadAccessError: Error, Sendable {
    case unavailable
}

private final class ClipboardHistoryPayloadReference: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPayload: ClipboardHistoryPayload?
    private var loader: (@Sendable () throws -> ClipboardHistoryPayload)?

    init(payload: ClipboardHistoryPayload) {
        cachedPayload = payload
        loader = nil
    }

    init(loader: @escaping @Sendable () throws -> ClipboardHistoryPayload) {
        cachedPayload = nil
        self.loader = loader
    }

    var cached: ClipboardHistoryPayload? {
        lock.withLock { cachedPayload }
    }

    func load() throws -> ClipboardHistoryPayload {
        let resolvedLoader: @Sendable () throws -> ClipboardHistoryPayload = try lock.withLock {
            if let cachedPayload {
                return { cachedPayload }
            }
            guard let loader else {
                throw ClipboardHistoryPayloadAccessError.unavailable
            }
            return loader
        }
        let loadedPayload = try resolvedLoader()
        return lock.withLock {
            if let cachedPayload {
                return cachedPayload
            }
            cachedPayload = loadedPayload
            return loadedPayload
        }
    }

    func configureLoader(
        _ loader: @escaping @Sendable () throws -> ClipboardHistoryPayload,
        discardCachedPayload: Bool
    ) {
        lock.withLock {
            self.loader = loader
            if discardCachedPayload {
                cachedPayload = nil
            }
        }
    }

    func discardCachedPayloadIfReloadable() {
        lock.withLock {
            guard loader != nil else { return }
            cachedPayload = nil
        }
    }
}

struct ClipboardHistoryItem: Codable, Equatable, Identifiable, Sendable {
    static let maximumSearchableCharacterCount = 16_000

    let id: UUID
    private let payloadReference: ClipboardHistoryPayloadReference
    let text: String
    let capturedAt: Date
    let sourceApplication: ClipboardSourceApplication?
    let kind: ClipboardHistoryContentKind
    let payloadByteCount: Int
    let filterContentKinds: Set<ClipboardHistoryContentKind>
    let fileURLs: [URL]
    let representationTypeIdentifiers: [String]
    let payloadDigest: Data
    let allowsRichTextImport: Bool
    let textCharacterCount: Int
    let textLineCount: Int
    let isSearchTextTruncated: Bool
    var isPinned: Bool
    var lastUsedAt: Date?
    private(set) var imageSearchText: String?
    var hasCompletedImageTextIndexing: Bool
    private(set) var searchIndex: ClipboardHistorySearchIndex

    init(
        id: UUID,
        payload: ClipboardHistoryPayload,
        capturedAt: Date,
        sourceApplication: ClipboardSourceApplication?,
        isPinned: Bool,
        lastUsedAt: Date?,
        imageSearchText: String? = nil,
        hasCompletedImageTextIndexing: Bool = false
    ) {
        self.id = id
        payloadReference = ClipboardHistoryPayloadReference(payload: payload)
        let searchableText = payload.searchableText
        text = String(searchableText.prefix(Self.maximumSearchableCharacterCount))
        self.capturedAt = capturedAt
        self.sourceApplication = sourceApplication
        kind = payload.kind
        payloadByteCount = payload.byteCount
        filterContentKinds = payload.filterContentKinds
        fileURLs = payload.fileURLs
        representationTypeIdentifiers = payload.representations.map(\.typeIdentifier)
        payloadDigest = Self.digest(payload)
        allowsRichTextImport = ClipboardRichTextPreviewPolicy.allowsFormattedImport(payload)
        textCharacterCount = searchableText.count
        textLineCount = Self.lineCount(searchableText)
        isSearchTextTruncated = searchableText.count > Self.maximumSearchableCharacterCount
        self.isPinned = isPinned
        self.lastUsedAt = lastUsedAt
        let boundedImageSearchText = imageSearchText.map {
            String($0.prefix(Self.maximumSearchableCharacterCount))
        }
        self.imageSearchText = boundedImageSearchText
        self.hasCompletedImageTextIndexing = hasCompletedImageTextIndexing
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: text,
            sourceApplication: sourceApplication,
            fileURLs: payload.fileURLs,
            imageSearchText: boundedImageSearchText
        )
    }

    init(
        id: UUID,
        text: String,
        capturedAt: Date,
        sourceApplication: ClipboardSourceApplication?,
        isPinned: Bool,
        lastUsedAt: Date?
    ) {
        self.init(
            id: id,
            payload: .plainText(text),
            capturedAt: capturedAt,
            sourceApplication: sourceApplication,
            isPinned: isPinned,
            lastUsedAt: lastUsedAt
        )
    }

    var payload: ClipboardHistoryPayload? { payloadReference.cached }

    var fileContentKinds: Set<ClipboardFileContentKind> {
        Set(fileURLs.compactMap(ClipboardFileContentKind.init(url:)))
    }

    func loadPayload() throws -> ClipboardHistoryPayload {
        try payloadReference.load()
    }

    func configurePayloadLoader(
        _ loader: @escaping @Sendable () throws -> ClipboardHistoryPayload,
        discardCachedPayload: Bool
    ) {
        payloadReference.configureLoader(loader, discardCachedPayload: discardCachedPayload)
    }

    func discardCachedPayloadIfReloadable() {
        payloadReference.discardCachedPayloadIfReloadable()
    }

    init(
        id: UUID,
        text: String,
        capturedAt: Date,
        sourceApplication: ClipboardSourceApplication?,
        kind: ClipboardHistoryContentKind,
        payloadByteCount: Int,
        filterContentKinds: Set<ClipboardHistoryContentKind>,
        fileURLs: [URL],
        representationTypeIdentifiers: [String],
        payloadDigest: Data,
        allowsRichTextImport: Bool,
        textCharacterCount: Int,
        textLineCount: Int,
        isSearchTextTruncated: Bool,
        isPinned: Bool,
        lastUsedAt: Date?,
        imageSearchText: String?,
        hasCompletedImageTextIndexing: Bool,
        payloadLoader: @escaping @Sendable () throws -> ClipboardHistoryPayload
    ) {
        self.id = id
        payloadReference = ClipboardHistoryPayloadReference(loader: payloadLoader)
        self.text = text
        self.capturedAt = capturedAt
        self.sourceApplication = sourceApplication
        self.kind = kind
        self.payloadByteCount = payloadByteCount
        self.filterContentKinds = filterContentKinds
        self.fileURLs = fileURLs
        self.representationTypeIdentifiers = representationTypeIdentifiers
        self.payloadDigest = payloadDigest
        self.allowsRichTextImport = allowsRichTextImport
        self.textCharacterCount = textCharacterCount
        self.textLineCount = textLineCount
        self.isSearchTextTruncated = isSearchTextTruncated
        self.isPinned = isPinned
        self.lastUsedAt = lastUsedAt
        self.imageSearchText = imageSearchText
        self.hasCompletedImageTextIndexing = hasCompletedImageTextIndexing
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: text,
            sourceApplication: sourceApplication,
            fileURLs: fileURLs,
            imageSearchText: imageSearchText
        )
    }

    mutating func setImageSearchText(_ recognizedText: String?) {
        let boundedText = recognizedText.map {
            String($0.prefix(Self.maximumSearchableCharacterCount))
        }
        imageSearchText = boundedText
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: text,
            sourceApplication: sourceApplication,
            fileURLs: fileURLs,
            imageSearchText: boundedText
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case payload
        case capturedAt
        case sourceApplication
        case isPinned
        case lastUsedAt
        case imageSearchText
        case hasCompletedImageTextIndexing
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let payload = try container.decode(ClipboardHistoryPayload.self, forKey: .payload)
        payloadReference = ClipboardHistoryPayloadReference(payload: payload)
        let searchableText = payload.searchableText
        text = String(searchableText.prefix(Self.maximumSearchableCharacterCount))
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        sourceApplication = try container.decodeIfPresent(
            ClipboardSourceApplication.self,
            forKey: .sourceApplication
        )
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        kind = payload.kind
        payloadByteCount = payload.byteCount
        filterContentKinds = payload.filterContentKinds
        fileURLs = payload.fileURLs
        representationTypeIdentifiers = payload.representations.map(\.typeIdentifier)
        payloadDigest = Self.digest(payload)
        allowsRichTextImport = ClipboardRichTextPreviewPolicy.allowsFormattedImport(payload)
        textCharacterCount = searchableText.count
        textLineCount = Self.lineCount(searchableText)
        isSearchTextTruncated = searchableText.count > Self.maximumSearchableCharacterCount
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        imageSearchText = try container.decodeIfPresent(String.self, forKey: .imageSearchText).map {
            String($0.prefix(Self.maximumSearchableCharacterCount))
        }
        hasCompletedImageTextIndexing = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedImageTextIndexing
        ) ?? false
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: text,
            sourceApplication: sourceApplication,
            fileURLs: payload.fileURLs,
            imageSearchText: imageSearchText
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(loadPayload(), forKey: .payload)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encodeIfPresent(sourceApplication, forKey: .sourceApplication)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(imageSearchText, forKey: .imageSearchText)
        if hasCompletedImageTextIndexing {
            try container.encode(true, forKey: .hasCompletedImageTextIndexing)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.capturedAt == rhs.capturedAt
            && lhs.sourceApplication == rhs.sourceApplication
            && lhs.kind == rhs.kind
            && lhs.payloadByteCount == rhs.payloadByteCount
            && lhs.filterContentKinds == rhs.filterContentKinds
            && lhs.fileURLs == rhs.fileURLs
            && lhs.representationTypeIdentifiers == rhs.representationTypeIdentifiers
            && lhs.payloadDigest == rhs.payloadDigest
            && lhs.allowsRichTextImport == rhs.allowsRichTextImport
            && lhs.textCharacterCount == rhs.textCharacterCount
            && lhs.textLineCount == rhs.textLineCount
            && lhs.isSearchTextTruncated == rhs.isSearchTextTruncated
            && lhs.isPinned == rhs.isPinned
            && lhs.lastUsedAt == rhs.lastUsedAt
            && lhs.imageSearchText == rhs.imageSearchText
            && lhs.hasCompletedImageTextIndexing == rhs.hasCompletedImageTextIndexing
    }

    fileprivate static func digest(_ payload: ClipboardHistoryPayload) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = (try? encoder.encode(payload)) ?? Data()
        return Data(SHA256.hash(data: encoded))
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }
}

enum ClipboardHistoryExpiration: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var interval: TimeInterval? {
        guard self != .never else { return nil }
        return TimeInterval(rawValue * 24 * 60 * 60)
    }
}

struct ClipboardHistorySettings: Equatable, Sendable {
    static let maximumSupportedItemCount = 10_000
    // Kept only to migrate the previously exposed unlimited setting.
    static let noItemCountLimit = -1
    static let defaultMaximumItemCount = 500
    static let defaultMaximumItemByteCount = 5 * 1_024 * 1_024
    static let defaultMaximumTotalPayloadByteCount = 64 * 1_024 * 1_024
    static let maximumSupportedTotalPayloadByteCount = 5 * 1_024 * 1_024 * 1_024

    var isPaused: Bool
    var maximumItemCount: Int
    var expiration: ClipboardHistoryExpiration
    var maximumItemByteCount: Int
    var maximumTotalPayloadByteCount: Int = defaultMaximumTotalPayloadByteCount
    var excludedApplications: [ClipboardExcludedApplication]

    static let defaults = ClipboardHistorySettings(
        isPaused: false,
        maximumItemCount: defaultMaximumItemCount,
        expiration: .thirtyDays,
        maximumItemByteCount: defaultMaximumItemByteCount,
        maximumTotalPayloadByteCount: defaultMaximumTotalPayloadByteCount,
        excludedApplications: [
            ClipboardExcludedApplication(
                bundleIdentifier: "com.apple.Passwords",
                name: "Passwords"
            ),
            ClipboardExcludedApplication(
                bundleIdentifier: "com.apple.keychainaccess",
                name: "Keychain Access"
            ),
            ClipboardExcludedApplication(
                bundleIdentifier: "com.1password.1password",
                name: "1Password"
            ),
            ClipboardExcludedApplication(
                bundleIdentifier: "com.bitwarden.desktop",
                name: "Bitwarden"
            ),
        ]
    )
}

enum ClipboardCaptureIgnoreReason: Equatable, Sendable {
    case paused
    case unsupportedType
    case producerMarkedPrivate
    case excludedApplication
    case empty
    case oversized
    case pinnedItemsFillCapacity
    case duplicateNewestItem
}

enum ClipboardCaptureDecision: Equatable, Sendable {
    case capture(ClipboardHistoryItem)
    case ignore(ClipboardCaptureIgnoreReason)
}

enum ClipboardCapturePolicy {
    static let ignoredProducerTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "net.antelle.keeweb",
    ]

    static func preflight(
        types: Set<String>,
        sourceApplication: ClipboardSourceApplication?,
        settings: ClipboardHistorySettings
    ) -> ClipboardCaptureIgnoreReason? {
        if settings.isPaused {
            return .paused
        }
        if !types.isDisjoint(with: ignoredProducerTypes) {
            return .producerMarkedPrivate
        }
        guard types.contains(where: ClipboardRepresentationType.isSupported) else {
            return .unsupportedType
        }
        if let bundleIdentifier = sourceApplication?.bundleIdentifier,
           settings.excludedApplications.contains(where: {
               $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
           }) {
            return .excludedApplication
        }
        return nil
    }

    static func evaluatePayload(
        _ payload: ClipboardHistoryPayload?,
        sourceApplication: ClipboardSourceApplication?,
        settings: ClipboardHistorySettings,
        newestItem: ClipboardHistoryItem?,
        now: Date = Date(),
        makeID: () -> UUID = UUID.init
    ) -> ClipboardCaptureDecision {
        guard let payload, !payload.pasteboardItems.isEmpty else {
            return .ignore(.empty)
        }
        guard payload.byteCount <= settings.maximumItemByteCount else {
            return .ignore(.oversized)
        }

        let text = payload.searchableText
        if payload.kind == .plainText {
            guard !normalizedText(text).isEmpty else {
                return .ignore(.empty)
            }
        }
        if let newestItem, payloadsAreDuplicates(payload, newestItem) {
            return .ignore(.duplicateNewestItem)
        }
        return .capture(ClipboardHistoryItem(
            id: makeID(),
            payload: payload,
            capturedAt: now,
            sourceApplication: sourceApplication,
            isPinned: false,
            lastUsedAt: nil
        ))
    }

    static func evaluateText(
        _ text: String?,
        sourceApplication: ClipboardSourceApplication?,
        settings: ClipboardHistorySettings,
        newestItem: ClipboardHistoryItem?,
        now: Date = Date(),
        makeID: () -> UUID = UUID.init
    ) -> ClipboardCaptureDecision {
        guard let text else { return .ignore(.empty) }
        return evaluatePayload(
            .plainText(text),
            sourceApplication: sourceApplication,
            settings: settings,
            newestItem: newestItem,
            now: now,
            makeID: makeID
        )
    }

    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func payloadsAreDuplicates(
        _ lhs: ClipboardHistoryPayload,
        _ rhs: ClipboardHistoryItem
    ) -> Bool {
        if lhs.kind == .plainText,
           rhs.kind == .plainText,
           !lhs.plainTexts.isEmpty,
           !rhs.text.isEmpty {
            return normalizedText(lhs.searchableText) == normalizedText(rhs.text)
        }
        return ClipboardHistoryItem.digest(lhs) == rhs.payloadDigest
    }
}

struct ClipboardHistoryUsage: Equatable, Sendable {
    let itemCount: Int
    let pinnedItemCount: Int
    let payloadByteCount: Int

    init(items: [ClipboardHistoryItem]) {
        itemCount = items.count
        pinnedItemCount = items.lazy.filter(\.isPinned).count
        payloadByteCount = items.reduce(0) { $0 + $1.payloadByteCount }
    }
}

struct ClipboardRetentionResult: Equatable, Sendable {
    let items: [ClipboardHistoryItem]
    let evictedUnpinnedItemCount: Int
    let isCaptureBlockedByPinnedItems: Bool
}

enum ClipboardRetentionPolicy {
    // Kept as the default and legacy single-file migration ceiling.
    static let maximumTotalPayloadByteCount = 64 * 1_024 * 1_024

    static func prune(
        _ items: [ClipboardHistoryItem],
        settings: ClipboardHistorySettings,
        now: Date = Date()
    ) -> [ClipboardHistoryItem] {
        evaluate(items, settings: settings, now: now).items
    }

    static func evaluate(
        _ items: [ClipboardHistoryItem],
        settings: ClipboardHistorySettings,
        now: Date = Date()
    ) -> ClipboardRetentionResult {
        let newestFirstItems: [ClipboardHistoryItem]
        if zip(items, items.dropFirst()).allSatisfy({ pair in
            pair.0.capturedAt >= pair.1.capturedAt
        }) {
            newestFirstItems = items
        } else {
            newestFirstItems = items.sorted(by: newestFirst)
        }
        let unexpired: [ClipboardHistoryItem]
        if let interval = settings.expiration.interval {
            let cutoff = now.addingTimeInterval(-interval)
            unexpired = newestFirstItems.filter { $0.isPinned || $0.capturedAt >= cutoff }
        } else {
            unexpired = newestFirstItems
        }
        let pinned = unexpired.filter(\.isPinned)
        let recent = unexpired.filter { !$0.isPinned }
        let maximumItemCount = settings.maximumItemCount == ClipboardHistorySettings.noItemCountLimit
            ? ClipboardHistorySettings.maximumSupportedItemCount
            : min(settings.maximumItemCount, ClipboardHistorySettings.maximumSupportedItemCount)

        // Pins are user-owned snippets and are never removed automatically. The count and
        // payload budgets therefore apply only to the remaining unpinned capacity.
        var retained = pinned
        let pinnedPayloadBytes = pinned.reduce(0) { $0 + $1.payloadByteCount }
        var retainedPayloadBytes = pinnedPayloadBytes
        let availableRecentCount = max(0, maximumItemCount - pinned.count)
        for item in recent.prefix(availableRecentCount) {
            let byteCount = item.payloadByteCount
            guard retainedPayloadBytes + byteCount <= settings.maximumTotalPayloadByteCount else {
                break
            }
            retained.append(item)
            retainedPayloadBytes += byteCount
        }
        let retainedIDs = Set(retained.map(\.id))
        let evictedUnpinnedItemCount = items.lazy.filter {
            !$0.isPinned && !retainedIDs.contains($0.id)
        }.count
        return ClipboardRetentionResult(
            items: unexpired.filter { retainedIDs.contains($0.id) },
            evictedUnpinnedItemCount: evictedUnpinnedItemCount,
            isCaptureBlockedByPinnedItems:
                pinned.count >= maximumItemCount
                || pinnedPayloadBytes >= settings.maximumTotalPayloadByteCount
        )
    }

    private static func newestFirst(_ lhs: ClipboardHistoryItem, _ rhs: ClipboardHistoryItem) -> Bool {
        lhs.capturedAt > rhs.capturedAt
    }
}

enum ClipboardHistorySearch {
    struct Result: Equatable, Sendable {
        let items: [ClipboardHistoryItem]
        let hasMore: Bool
    }

    private struct WordFragmentSearchState: Hashable {
        let queryOffset: Int
        let wordIndex: Int
        let minimumFragmentLength: Int
        let usedWordCount: Int
    }

    static func filter(_ items: [ClipboardHistoryItem], query: String) -> [ClipboardHistoryItem] {
        result(items, query: query, limit: nil).items
    }

    static func result(
        _ items: [ClipboardHistoryItem],
        query: String,
        limit: Int?
    ) -> Result {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            guard let limit, items.count > limit else {
                return Result(items: items, hasMore: false)
            }
            return Result(items: Array(items.prefix(limit)), hasMore: true)
        }
        let normalizedQuery = normalized(trimmedQuery)
        let queryTokens = tokens(in: normalizedQuery)
        let compactQuery = compactTokens(queryTokens)
        var matches: [ClipboardHistoryItem] = []
        for item in items {
            guard !Task.isCancelled else { return Result(items: [], hasMore: false) }
            let normalizedText = item.searchIndex.normalizedText
            let searchableTokens = item.searchIndex.tokens
            if allowsExactSubstringMatch(
                normalizedQuery,
                compactQuery: compactQuery
            ) && normalizedText.contains(normalizedQuery) {
                matches.append(item)
            } else if !queryTokens.isEmpty, queryTokens.allSatisfy({ queryToken in
                searchableTokens.contains { $0.hasPrefix(queryToken) }
            }) {
                matches.append(item)
            } else if compactQueryMatchesWordFragments(
                compactQuery,
                words: searchableTokens
            ) {
                matches.append(item)
            }
            if let limit, matches.count > limit {
                return Result(items: Array(matches.prefix(limit)), hasMore: true)
            }
        }
        return Result(items: matches, hasMore: false)
    }

    static func makeIndex(
        text: String,
        sourceApplication: ClipboardSourceApplication?,
        fileURLs: [URL],
        imageSearchText: String?
    ) -> ClipboardHistorySearchIndex {
        let searchableText = [
            text,
            sourceApplication?.name,
            sourceApplication?.bundleIdentifier,
            fileURLs.map(\.path).joined(separator: " "),
            imageSearchText,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        let normalizedText = normalized(searchableText)
        return ClipboardHistorySearchIndex(
            normalizedText: normalizedText,
            tokens: tokens(in: normalizedText)
        )
    }

    private static func compactTokens(_ tokens: [String]) -> String {
        tokens.joined()
    }

    private static func allowsExactSubstringMatch(
        _ query: String,
        compactQuery: String
    ) -> Bool {
        if compactQuery.count >= 3 {
            return true
        }
        return query.unicodeScalars.contains { !$0.isASCII }
    }

    private static func compactQueryMatchesWordFragments(
        _ query: String,
        words: [String]
    ) -> Bool {
        let queryCharacters = Array(query)
        guard queryCharacters.count >= 2, words.count >= 2 else { return false }
        let wordCharacters = words.map(Array.init)
        var memoizedResults: [WordFragmentSearchState: Bool] = [:]

        func contains(_ fragment: [Character], in word: [Character]) -> Bool {
            guard !fragment.isEmpty, fragment.count <= word.count else { return false }
            for startIndex in 0...(word.count - fragment.count) {
                let endIndex = startIndex + fragment.count
                if Array(word[startIndex..<endIndex]) == fragment {
                    return true
                }
            }
            return false
        }

        func matches(
            queryOffset: Int,
            wordIndex: Int,
            minimumFragmentLength: Int,
            usedWordCount: Int
        ) -> Bool {
            if queryOffset == queryCharacters.count {
                return usedWordCount >= 2
            }
            guard wordIndex < wordCharacters.count else { return false }
            let state = WordFragmentSearchState(
                queryOffset: queryOffset,
                wordIndex: wordIndex,
                minimumFragmentLength: minimumFragmentLength,
                usedWordCount: min(usedWordCount, 2)
            )
            if let memoizedResult = memoizedResults[state] {
                return memoizedResult
            }
            let word = wordCharacters[wordIndex]
            let remainingCount = queryCharacters.count - queryOffset
            let maximumPrefixLength = min(word.count, remainingCount)
            guard maximumPrefixLength >= minimumFragmentLength else {
                memoizedResults[state] = false
                return false
            }

            for prefixLength in minimumFragmentLength...maximumPrefixLength {
                let queryRange = queryOffset..<(queryOffset + prefixLength)
                guard Array(queryCharacters[queryRange]) == Array(word.prefix(prefixLength)) else {
                    break
                }
                if matchesWordFragment(
                    length: prefixLength,
                    queryOffset: queryOffset,
                    wordIndex: wordIndex,
                    usedWordCount: usedWordCount
                ) {
                    memoizedResults[state] = true
                    return true
                }
            }

            if usedWordCount == 0, maximumPrefixLength >= 2 {
                for fragmentLength in 2...maximumPrefixLength {
                    let queryRange = queryOffset..<(queryOffset + fragmentLength)
                    let fragment = Array(queryCharacters[queryRange])
                    guard contains(fragment, in: word) else { continue }
                    if matchesWordFragment(
                        length: fragmentLength,
                        queryOffset: queryOffset,
                        wordIndex: wordIndex,
                        usedWordCount: usedWordCount
                    ) {
                        memoizedResults[state] = true
                        return true
                    }
                }
            }
            memoizedResults[state] = false
            return false
        }

        func matchesWordFragment(
            length: Int,
            queryOffset: Int,
            wordIndex: Int,
            usedWordCount: Int
        ) -> Bool {
            let nextQueryOffset = queryOffset + length
            if nextQueryOffset == queryCharacters.count {
                return usedWordCount + 1 >= 2
            }
            for nextWordIndex in (wordIndex + 1)..<wordCharacters.count {
                if matches(
                    queryOffset: nextQueryOffset,
                    wordIndex: nextWordIndex,
                    minimumFragmentLength: nextWordIndex == wordIndex + 1 ? 1 : 3,
                    usedWordCount: usedWordCount + 1
                ) {
                    return true
                }
            }
            return false
        }

        for startIndex in wordCharacters.indices {
            if matches(
                queryOffset: 0,
                wordIndex: startIndex,
                minimumFragmentLength: 1,
                usedWordCount: 0
            ) {
                return true
            }
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private static func tokens(in value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
