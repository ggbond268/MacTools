import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit

enum ClipboardSavedItemKind: String, Codable, CaseIterable, Sendable {
    case snippet
    case clip
}

struct ClipboardSavedItem: Identifiable, Equatable, Sendable {
    static let maximumTitleCharacterCount = 160
    static let maximumTagCount = 24
    static let maximumTagCharacterCount = 48
    static let maximumKeywordCharacterCount = 64
    static let maximumSnippetUTF8ByteCount = 5 * 1_024 * 1_024
    static let maximumKeywordExpansionCacheByteCount = 16 * 1_024 * 1_024

    let id: UUID
    var title: String
    var tags: [String]
    var keyword: String?
    var isFavorite: Bool
    let savedKind: ClipboardSavedItemKind
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    let sourceApplication: ClipboardSourceApplication?
    let contentKind: ClipboardHistoryContentKind
    let payloadByteCount: Int
    let fileURLs: [URL]
    let fileReferenceCount: Int
    let linkURLs: [URL]
    let representationTypeIdentifiers: [String]
    let payloadDigest: Data
    var templateText: String?
    var templateSearchText: String?
    var hasDynamicTemplateContent: Bool
    var clipSearchText: String?
    var imageSearchText: String?
    private(set) var searchIndex: ClipboardHistorySearchIndex
    private let payloadReference: ClipboardHistoryPayloadReference

    init(
        id: UUID = UUID(),
        title: String,
        tags: [String] = [],
        keyword: String? = nil,
        isFavorite: Bool = false,
        savedKind: ClipboardSavedItemKind,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sourceApplication: ClipboardSourceApplication? = nil,
        payload: ClipboardHistoryPayload,
        templateText: String? = nil,
        clipSearchText: String? = nil,
        imageSearchText: String? = nil
    ) {
        self.id = id
        self.title = Self.normalizedTitle(title, fallback: payload.searchableText)
        self.tags = Self.normalizedTags(tags)
        self.keyword = Self.normalizedKeyword(keyword)
        self.isFavorite = isFavorite
        self.savedKind = savedKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.sourceApplication = sourceApplication
        contentKind = payload.kind
        payloadByteCount = payload.byteCount
        fileURLs = payload.metadataFileURLs
        fileReferenceCount = payload.fileURLs.count
        linkURLs = payload.metadataLinkURLs
        representationTypeIdentifiers = payload.metadataRepresentationTypeIdentifiers
        payloadDigest = ClipboardHistoryItem.digest(payload)
        self.templateText = templateText
        templateSearchText = templateText.map {
            String($0.prefix(ClipboardHistoryItem.maximumSearchableCharacterCount))
        }
        hasDynamicTemplateContent = ClipboardSnippetTemplateEngine.containsDynamicContent(
            templateText ?? ""
        )
        let literalSearchText = clipSearchText ?? (savedKind == .clip ? payload.searchableText : nil)
        self.clipSearchText = literalSearchText.map {
            String($0.prefix(ClipboardHistoryItem.maximumSearchableCharacterCount))
        }
        self.imageSearchText = imageSearchText.map {
            String($0.prefix(ClipboardHistoryItem.maximumSearchableCharacterCount))
        }
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: Self.searchableText(
                title: self.title,
                tags: self.tags,
                keyword: self.keyword,
                templateText: templateSearchText,
                clipSearchText: self.clipSearchText
            ),
            sourceApplication: sourceApplication,
            fileURLs: payload.metadataFileURLs,
            linkURLs: payload.metadataLinkURLs,
            imageSearchText: self.imageSearchText
        )
        payloadReference = ClipboardHistoryPayloadReference(payload: payload)
    }

    init(
        id: UUID,
        title: String,
        tags: [String],
        keyword: String?,
        isFavorite: Bool,
        savedKind: ClipboardSavedItemKind,
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date?,
        sourceApplication: ClipboardSourceApplication?,
        contentKind: ClipboardHistoryContentKind,
        payloadByteCount: Int,
        fileURLs: [URL],
        fileReferenceCount: Int,
        linkURLs: [URL],
        representationTypeIdentifiers: [String],
        payloadDigest: Data,
        templateSearchText: String?,
        hasDynamicTemplateContent: Bool,
        clipSearchText: String?,
        imageSearchText: String?,
        payloadLoader: @escaping @Sendable () throws -> ClipboardHistoryPayload
    ) {
        self.id = id
        self.title = Self.normalizedTitle(title, fallback: "")
        self.tags = Self.normalizedTags(tags)
        self.keyword = Self.normalizedKeyword(keyword)
        self.isFavorite = isFavorite
        self.savedKind = savedKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.sourceApplication = sourceApplication
        self.contentKind = contentKind
        self.payloadByteCount = payloadByteCount
        self.fileURLs = fileURLs
        self.fileReferenceCount = fileReferenceCount
        self.linkURLs = linkURLs
        self.representationTypeIdentifiers = representationTypeIdentifiers
        self.payloadDigest = payloadDigest
        templateText = nil
        self.templateSearchText = templateSearchText
        self.hasDynamicTemplateContent = hasDynamicTemplateContent
        self.clipSearchText = clipSearchText
        self.imageSearchText = imageSearchText
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: Self.searchableText(
                title: self.title,
                tags: self.tags,
                keyword: self.keyword,
                templateText: templateSearchText,
                clipSearchText: clipSearchText
            ),
            sourceApplication: sourceApplication,
            fileURLs: fileURLs,
            linkURLs: linkURLs,
            imageSearchText: imageSearchText
        )
        payloadReference = ClipboardHistoryPayloadReference(loader: payloadLoader)
    }

    var isSnippet: Bool { savedKind == .snippet }

    var searchableText: String {
        ([title] + tags + [keyword, templateSearchText, clipSearchText, imageSearchText].compactMap { $0 })
            .joined(separator: "\n")
    }

    func loadPayload() throws -> ClipboardHistoryPayload {
        try payloadReference.load()
    }

    func loadPayloadAsync() async throws -> ClipboardHistoryPayload {
        try await payloadReference.loadAsync()
    }

    func discardCachedPayloadIfReloadable() {
        payloadReference.discardCachedPayloadIfReloadable()
    }

    var isPayloadCachedForTesting: Bool { payloadReference.isCached }
    var waitingPayloadLoaderCountForTesting: Int {
        payloadReference.waitingLoaderCountForTesting
    }

    mutating func updateMetadata(
        title: String,
        tags: [String],
        keyword: String?,
        isFavorite: Bool,
        templateText: String?,
        updatedAt: Date
    ) {
        self.title = Self.normalizedTitle(title, fallback: templateText ?? clipSearchText ?? "")
        self.tags = Self.normalizedTags(tags)
        self.keyword = Self.normalizedKeyword(keyword)
        self.isFavorite = isFavorite
        self.templateText = templateText
        templateSearchText = templateText.map {
            String($0.prefix(ClipboardHistoryItem.maximumSearchableCharacterCount))
        }
        hasDynamicTemplateContent = ClipboardSnippetTemplateEngine.containsDynamicContent(
            templateText ?? ""
        )
        self.updatedAt = updatedAt
        refreshSearchIndex()
    }

    mutating func updateFavorite(_ isFavorite: Bool, updatedAt: Date) {
        self.isFavorite = isFavorite
        self.updatedAt = updatedAt
    }

    func reloadingPayload(using persistence: any ClipboardSavedLibraryPersisting) -> Self {
        Self(
            id: id,
            title: title,
            tags: tags,
            keyword: keyword,
            isFavorite: isFavorite,
            savedKind: savedKind,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt,
            sourceApplication: sourceApplication,
            contentKind: contentKind,
            payloadByteCount: payloadByteCount,
            fileURLs: fileURLs,
            fileReferenceCount: fileReferenceCount,
            linkURLs: linkURLs,
            representationTypeIdentifiers: representationTypeIdentifiers,
            payloadDigest: payloadDigest,
            templateSearchText: templateSearchText,
            hasDynamicTemplateContent: hasDynamicTemplateContent,
            clipSearchText: clipSearchText,
            imageSearchText: imageSearchText,
            payloadLoader: { try persistence.loadPayload(id: id) }
        )
    }

    func historyPresentationItem() -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: id,
            text: templateText ?? templateSearchText ?? title,
            capturedAt: updatedAt,
            sourceApplication: sourceApplication,
            kind: contentKind,
            payloadByteCount: payloadByteCount,
            filterContentKinds: [contentKind],
            fileURLs: fileURLs,
            fileReferenceCount: fileReferenceCount,
            linkURLs: linkURLs,
            representationTypeIdentifiers: representationTypeIdentifiers,
            payloadDigest: payloadDigest,
            allowsRichTextImport: contentKind == .richText,
            textCharacterCount: templateText?.count ?? templateSearchText?.count ?? title.count,
            textLineCount: max(1, (templateText ?? templateSearchText)?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 1),
            isSearchTextTruncated: false,
            isPinned: false,
            lastUsedAt: lastUsedAt,
            imageSearchText: imageSearchText,
            hasCompletedImageTextIndexing: imageSearchText != nil,
            payloadLoader: { try loadPayload() }
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.tags == rhs.tags
            && lhs.keyword == rhs.keyword
            && lhs.isFavorite == rhs.isFavorite
            && lhs.savedKind == rhs.savedKind
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.lastUsedAt == rhs.lastUsedAt
            && lhs.sourceApplication == rhs.sourceApplication
            && lhs.contentKind == rhs.contentKind
            && lhs.payloadByteCount == rhs.payloadByteCount
            && lhs.fileURLs == rhs.fileURLs
            && lhs.fileReferenceCount == rhs.fileReferenceCount
            && lhs.linkURLs == rhs.linkURLs
            && lhs.representationTypeIdentifiers == rhs.representationTypeIdentifiers
            && lhs.payloadDigest == rhs.payloadDigest
            && lhs.templateText == rhs.templateText
            && lhs.templateSearchText == rhs.templateSearchText
            && lhs.hasDynamicTemplateContent == rhs.hasDynamicTemplateContent
            && lhs.clipSearchText == rhs.clipSearchText
            && lhs.imageSearchText == rhs.imageSearchText
    }

    static func normalizedTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackLine = fallback.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? ""
        let candidate = trimmed.isEmpty ? fallbackLine : trimmed
        return String((candidate.isEmpty ? "—" : candidate).prefix(maximumTitleCharacterCount))
    }

    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        normalized.reserveCapacity(min(tags.count, maximumTagCount))

        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let candidate = String(trimmed.prefix(maximumTagCharacterCount))
            guard seen.insert(candidate.lowercased()).inserted else { continue }
            normalized.append(candidate)
            if normalized.count == maximumTagCount { break }
        }
        return normalized
    }

    static func normalizedKeyword(_ keyword: String?) -> String? {
        guard let keyword else { return nil }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \Character.isWhitespace) else { return nil }
        return String(trimmed.prefix(maximumKeywordCharacterCount))
    }

    private mutating func refreshSearchIndex() {
        searchIndex = ClipboardHistorySearch.makeIndex(
            text: Self.searchableText(
                title: title,
                tags: tags,
                keyword: keyword,
                templateText: templateSearchText,
                clipSearchText: clipSearchText
            ),
            sourceApplication: sourceApplication,
            fileURLs: fileURLs,
            linkURLs: linkURLs,
            imageSearchText: imageSearchText
        )
    }

    private static func searchableText(
        title: String,
        tags: [String],
        keyword: String?,
        templateText: String?,
        clipSearchText: String?
    ) -> String {
        ([title] + tags + [keyword, templateText, clipSearchText].compactMap { $0 })
            .joined(separator: "\n")
    }
}

struct ClipboardSnippetDraft: Equatable, Sendable {
    var id: UUID?
    var title: String
    var content: String
    var tags: [String]
    var keyword: String?
    var isFavorite: Bool
    var isNew = false

    static let empty = Self(
        id: UUID(),
        title: "",
        content: "",
        tags: [],
        keyword: nil,
        isFavorite: false,
        isNew: true
    )
}

struct ClipboardSavedMetadataDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var tags: [String]
}

enum ClipboardSavedLibraryError: Error, Equatable, LocalizedError, Sendable {
    case duplicateKeyword(String)
    case invalidKeyword
    case snippetTooLarge(maximumByteCount: Int)
    case keywordExpansionCacheFull(maximumByteCount: Int)
    case plainTextUnavailable

    var errorDescription: String? {
        switch self {
        case let .duplicateKeyword(keyword):
            "The keyword \(keyword) is already assigned to another snippet."
        case .invalidKeyword:
            "A keyword cannot contain spaces or line breaks."
        case let .snippetTooLarge(maximumByteCount):
            "A snippet cannot exceed \(ByteCountFormatter.string(fromByteCount: Int64(maximumByteCount), countStyle: .file))."
        case let .keywordExpansionCacheFull(maximumByteCount):
            "Keyword-enabled snippets cannot exceed \(ByteCountFormatter.string(fromByteCount: Int64(maximumByteCount), countStyle: .file)) in total."
        case .plainTextUnavailable:
            "This saved item doesn’t contain pasteable text."
        }
    }
}

enum ClipboardSnippetTemplateError: Error, Equatable, LocalizedError, Sendable {
    case unknownMacro(String)
    case invalidMacroSyntax
    case invalidDateFormat
    case invalidVariableOptions
    case multipleCursorMarkers

    var errorDescription: String? {
        switch self {
        case let .unknownMacro(name): "Unknown snippet variable: \(name)"
        case .invalidMacroSyntax: "The snippet contains an invalid variable expression."
        case .invalidDateFormat: "The snippet contains an invalid date or time format."
        case .invalidVariableOptions: "Check the variable options, offset, and time zone."
        case .multipleCursorMarkers: "A snippet can contain only one cursor marker."
        }
    }

    func localizedMessage(_ localization: PluginLocalization) -> String {
        switch self {
        case let .unknownMacro(name):
            localization.format(
                "saved.error.unknownMacro",
                defaultValue: "Unknown snippet variable: %@",
                name
            )
        case .invalidDateFormat:
            localization.string(
                "saved.error.invalidDateFormat",
                defaultValue: "The snippet contains an invalid date or time format."
            )
        case .invalidVariableOptions:
            localization.string(
                "saved.error.invalidVariableOptions",
                defaultValue: "Check the variable options, offset, and time zone."
            )
        case .invalidMacroSyntax:
            localization.string(
                "saved.error.invalidMacroSyntax",
                defaultValue: "The snippet contains an invalid variable expression."
            )
        case .multipleCursorMarkers:
            localization.string(
                "saved.error.multipleCursorMarkers",
                defaultValue: "A snippet can contain only one cursor marker."
            )
        }
    }
}

struct ClipboardSnippetExpansionContext: Sendable {
    var date: Date
    var locale: Locale
    var timeZone: TimeZone
    var clipboardText: String?
    var uuid: @Sendable () -> UUID

    static func current(clipboardText: String?) -> Self {
        Self(
            date: Date(),
            locale: .current,
            timeZone: .current,
            clipboardText: clipboardText,
            uuid: { UUID() }
        )
    }
}

struct ClipboardSnippetExpansion: Equatable, Sendable {
    let text: String
    let cursorOffsetFromEnd: Int?

    var cursorUTF16OffsetFromEnd: Int? {
        guard let cursorOffsetFromEnd,
              let cursorIndex = text.index(
                  text.endIndex,
                  offsetBy: -cursorOffsetFromEnd,
                  limitedBy: text.startIndex
              ) else { return nil }
        return text[cursorIndex...].utf16.count
    }
}

enum ClipboardSnippetCursorPositioner {
    static func moveCursorBackward(
        in processIdentifier: pid_t,
        byUTF16Offset offset: Int
    ) -> Bool {
        guard offset > 0 else { return true }
        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedElement = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return false
        }
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selectedRange),
              selectedRange.length == 0,
              selectedRange.location >= offset else {
            return false
        }
        selectedRange.location -= offset
        guard let updatedRange = AXValueCreate(.cfRange, &selectedRange) else { return false }
        return AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            updatedRange
        ) == .success
    }
}

enum ClipboardSnippetTemplateEngine {
    private static let expression = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z][A-Za-z0-9-]*)((?:\s+[A-Za-z][A-Za-z0-9-]*="(?:[^"\\]|\\.)*")*)\s*\}\}"#
    )
    private static let optionExpression = try! NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9-]*)=("(?:[^"\\]|\\.)*")"#
    )

    static func expand(
        _ template: String,
        context: ClipboardSnippetExpansionContext
    ) throws -> ClipboardSnippetExpansion {
        let matches = try validatedMatches(template)
        var output = ""
        var literalStart = template.startIndex
        let cursorSentinel = "\u{F8FF}MACTOOLS-CLIPBOARD-CURSOR-\(UUID().uuidString)\u{F8FF}"
        var hasCursor = false

        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: template),
                  let nameRange = Range(match.range(at: 1), in: template),
                  let optionsRange = Range(match.range(at: 2), in: template) else { continue }
            output += template[literalStart..<wholeRange.lowerBound]
                .replacingOccurrences(of: #"\{{"#, with: "{{")
            let name = String(template[nameRange]).lowercased()
            let options = try parseOptions(String(template[optionsRange]))
            let replacement: String
            switch name {
            case "date", "time", "datetime":
                try requireOptions(options, allowed: ["format", "offset", "timezone"])
                let zone: TimeZone
                if let identifier = options["timezone"] {
                    guard let requestedZone = TimeZone(identifier: identifier) else {
                        throw ClipboardSnippetTemplateError.invalidVariableOptions
                    }
                    zone = requestedZone
                } else {
                    zone = context.timeZone
                }
                replacement = try formattedDate(
                    adjustedDate(context.date, offset: options["offset"], timeZone: zone),
                    format: options["format"],
                    locale: context.locale,
                    timeZone: zone,
                    kind: name == "date" ? .date : name == "time" ? .time : .dateTime
                )
            case "clipboard":
                try requireOptions(options, allowed: ["trim", "case", "fallback"])
                guard options["trim"] == nil || ["true", "false"].contains(options["trim"]!),
                      options["case"] == nil || ["upper", "lower"].contains(options["case"]!) else {
                    throw ClipboardSnippetTemplateError.invalidVariableOptions
                }
                var value = context.clipboardText ?? ""
                if options["trim"] == "true" { value = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                if value.isEmpty { value = options["fallback"] ?? "" }
                if options["case"] == "upper" { value = value.uppercased(with: context.locale) }
                if options["case"] == "lower" { value = value.lowercased(with: context.locale) }
                replacement = value
            case "uuid":
                try requireOptions(options, allowed: [])
                replacement = context.uuid().uuidString
            case "cursor":
                try requireOptions(options, allowed: [])
                guard !hasCursor else {
                    throw ClipboardSnippetTemplateError.multipleCursorMarkers
                }
                replacement = cursorSentinel
                hasCursor = true
            default:
                throw ClipboardSnippetTemplateError.unknownMacro(name)
            }
            output += replacement
            literalStart = wholeRange.upperBound
        }

        // Only template literals are unescaped; clipboard/fallback content is never interpreted.
        output += template[literalStart...].replacingOccurrences(of: #"\{{"#, with: "{{")
        let cursorOffset: Int?
        if let cursorRange = output.range(of: cursorSentinel) {
            cursorOffset = output.distance(from: cursorRange.upperBound, to: output.endIndex)
            output.removeSubrange(cursorRange)
        } else {
            cursorOffset = nil
        }
        return ClipboardSnippetExpansion(text: output, cursorOffsetFromEnd: cursorOffset)
    }

    static func containsDynamicContent(_ template: String) -> Bool {
        (try? validatedMatches(template).isEmpty == false) ?? false
    }

    private static func validatedMatches(_ template: String) throws -> [NSTextCheckingResult] {
        let source = template as NSString
        var matches: [NSTextCheckingResult] = []
        var location = 0
        while location < source.length {
            let remaining = NSRange(location: location, length: source.length - location)
            let opening = source.range(of: "{{", options: [], range: remaining)
            let closing = source.range(of: "}}", options: [], range: remaining)
            if closing.location != NSNotFound,
               (opening.location == NSNotFound || closing.location < opening.location) {
                throw ClipboardSnippetTemplateError.invalidMacroSyntax
            }
            guard opening.location != NSNotFound else { return matches }

            if isEscaped(location: opening.location, in: source) {
                let literalRemainder = NSRange(
                    location: NSMaxRange(opening),
                    length: source.length - NSMaxRange(opening)
                )
                let literalClosing = source.range(of: "}}", options: [], range: literalRemainder)
                location = literalClosing.location == NSNotFound
                    ? NSMaxRange(opening)
                    : NSMaxRange(literalClosing)
                continue
            }

            let macroRange = NSRange(
                location: opening.location,
                length: source.length - opening.location
            )
            guard let match = expression.firstMatch(in: template, options: .anchored, range: macroRange) else {
                throw ClipboardSnippetTemplateError.invalidMacroSyntax
            }
            matches.append(match)
            location = NSMaxRange(match.range)
        }
        return matches
    }

    private static func parseOptions(_ source: String) throws -> [String: String] {
        var options: [String: String] = [:]
        for match in optionExpression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source),
                  let value = try? JSONDecoder().decode(String.self, from: Data(source[valueRange].utf8)),
                  options[String(source[nameRange])] == nil else {
                throw ClipboardSnippetTemplateError.invalidVariableOptions
            }
            options[String(source[nameRange])] = value
        }
        return options
    }

    private static func requireOptions(_ options: [String: String], allowed: Set<String>) throws {
        guard Set(options.keys).isSubset(of: allowed) else {
            throw ClipboardSnippetTemplateError.invalidVariableOptions
        }
    }

    private static func adjustedDate(_ date: Date, offset: String?, timeZone: TimeZone) throws -> Date {
        guard let offset else { return date }
        let components: [Character: Calendar.Component] = [
            "s": .second, "m": .minute, "h": .hour, "d": .day,
            "w": .weekOfYear, "M": .month, "y": .year
        ]
        guard let unit = offset.last, let component = components[unit],
              let value = Int(offset.dropLast()), (-1_000_000...1_000_000).contains(value) else {
            throw ClipboardSnippetTemplateError.invalidVariableOptions
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let adjusted = calendar.date(byAdding: component, value: value, to: date),
              (1...9999).contains(calendar.component(.year, from: adjusted)) else {
            throw ClipboardSnippetTemplateError.invalidVariableOptions
        }
        return adjusted
    }

    private static func isEscaped(location: Int, in source: NSString) -> Bool {
        guard location > 0 else { return false }
        var cursor = location - 1
        var slashCount = 0
        while cursor >= 0, source.character(at: cursor) == 92 {
            slashCount += 1
            cursor -= 1
        }
        return slashCount.isMultiple(of: 2) == false
    }

    private enum DateKind {
        case date
        case time
        case dateTime
    }

    private static func formattedDate(
        _ date: Date,
        format: String?,
        locale: Locale,
        timeZone: TimeZone,
        kind: DateKind
    ) throws -> String {
        if let format {
            guard !format.isEmpty, format.count <= 128,
                  format.filter({ $0 == "'" }).count.isMultiple(of: 2) else {
                throw ClipboardSnippetTemplateError.invalidDateFormat
            }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch kind {
        case .date:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case .time:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .dateTime:
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
}

protocol ClipboardSavedLibraryPersisting: Sendable {
    func prepare() throws
    func load() throws -> [ClipboardSavedItem]
    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws
    func loadPayload(id: UUID) throws -> ClipboardHistoryPayload
    func updateLastUsedAt(id: UUID, date: Date) throws
    func delete(id: UUID) throws
    func removeAll() throws
}

struct UnavailableClipboardSavedLibraryStore: ClipboardSavedLibraryPersisting {
    func prepare() throws { throw ClipboardHistoryStoreError.unavailableStorage }
    func load() throws -> [ClipboardSavedItem] { throw ClipboardHistoryStoreError.unavailableStorage }
    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws {
        throw ClipboardHistoryStoreError.unavailableStorage
    }
    func loadPayload(id: UUID) throws -> ClipboardHistoryPayload {
        throw ClipboardHistoryStoreError.unavailableStorage
    }
    func updateLastUsedAt(id: UUID, date: Date) throws {
        throw ClipboardHistoryStoreError.unavailableStorage
    }
    func delete(id: UUID) throws { throw ClipboardHistoryStoreError.unavailableStorage }
    func removeAll() throws {}
}

private final class ClipboardSavedLibraryPersistenceWorker: @unchecked Sendable {
    private let persistence: any ClipboardSavedLibraryPersisting
    private let queue = DispatchQueue(label: "cc.ggbond.mactools.clipboard.saved-library.persistence")

    init(persistence: any ClipboardSavedLibraryPersisting) {
        self.persistence = persistence
    }

    func load() async throws -> [ClipboardSavedItem] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [persistence] in
                continuation.resume(with: Result { try persistence.load() })
            }
        }
    }

    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [persistence] in
                continuation.resume(with: Result {
                    try persistence.save(item, payloadChanged: payloadChanged)
                })
            }
        }
    }

    func updateLastUsedAt(id: UUID, date: Date) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [persistence] in
                continuation.resume(with: Result {
                    try persistence.updateLastUsedAt(id: id, date: date)
                })
            }
        }
    }

    func delete(id: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [persistence] in
                continuation.resume(with: Result { try persistence.delete(id: id) })
            }
        }
    }

    func removeAll() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [persistence] in
                continuation.resume(with: Result { try persistence.removeAll() })
            }
        }
    }

    func flush() {
        queue.sync {}
    }
}

private actor ClipboardSavedLibraryMutationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard !isLocked else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }
        isLocked = true
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum ClipboardSavedLibrarySearch {
    struct Result: Equatable, Sendable {
        let items: [ClipboardSavedItem]
        let hasMore: Bool
    }

    static func result(
        items: [ClipboardSavedItem],
        query: String,
        limit: Int,
        itemsAreSorted: Bool = false
    ) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [ClipboardSavedItem] = []
        matches.reserveCapacity(min(items.count, max(limit + 1, 1)))
        for item in items {
            guard !Task.isCancelled else { return Result(items: [], hasMore: false) }
            guard trimmed.isEmpty
                || ClipboardHistorySearch.matches(index: item.searchIndex, query: trimmed) else {
                continue
            }
            matches.append(item)
            if itemsAreSorted, matches.count > limit {
                return Result(items: Array(matches.prefix(limit)), hasMore: true)
            }
        }
        guard !Task.isCancelled else { return Result(items: [], hasMore: false) }
        let ordered = itemsAreSorted ? matches : sorted(matches)
        guard !Task.isCancelled else { return Result(items: [], hasMore: false) }
        return Result(
            items: Array(ordered.prefix(limit)),
            hasMore: ordered.count > limit
        )
    }

    static func sorted(_ items: [ClipboardSavedItem]) -> [ClipboardSavedItem] {
        items.sorted { lhs, rhs in
            let lhsActivity = lhs.lastUsedAt ?? lhs.updatedAt
            let rhsActivity = rhs.lastUsedAt ?? rhs.updatedAt
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

@MainActor
final class ClipboardSavedLibraryController: ObservableObject {
    @Published private(set) var items: [ClipboardSavedItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var fatalErrorMessage: String?
    @Published private(set) var itemLoadErrorMessages: [UUID: String] = [:]
    @Published private(set) var isLoaded = false

    var onChange: (() -> Void)?
    var onPasteboardWrite: (() -> Void)?

    private let pasteboard: any ClipboardPasteboardAccess
    private let persistence: any ClipboardSavedLibraryPersisting
    private let worker: ClipboardSavedLibraryPersistenceWorker
    private let mutationGate = ClipboardSavedLibraryMutationGate()
    private let errorMessageProvider: (Error) -> String
    private var loadTask: Task<Void, Never>?
    private var keywordTemplateLoadTask: Task<Void, Never>?
    private var keywordCacheRevision: UInt64 = 0
    private var keywordTemplatesByID: [UUID: String] = [:]
    private var reservedKeywordIdentities: Set<String> = []
    init(
        pasteboard: any ClipboardPasteboardAccess,
        persistence: any ClipboardSavedLibraryPersisting,
        errorMessageProvider: @escaping (Error) -> String = { $0.localizedDescription }
    ) {
        self.pasteboard = pasteboard
        self.persistence = persistence
        worker = ClipboardSavedLibraryPersistenceWorker(persistence: persistence)
        self.errorMessageProvider = errorMessageProvider
    }

    func start() {
        guard !isLoaded, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedItems = try await worker.load()
                guard !Task.isCancelled else { return }
                let snippets = loadedItems.filter(\.isSnippet)
                items = ClipboardSavedLibrarySearch.sorted(snippets)
                for legacyClip in loadedItems where !legacyClip.isSnippet {
                    try? await worker.delete(id: legacyClip.id)
                }
                errorMessage = nil
                fatalErrorMessage = nil
                isLoaded = true
                loadTask = nil
                onChange?()
                reloadKeywordTemplateCache()
            } catch {
                guard !Task.isCancelled else { return }
                fatalErrorMessage = errorMessageProvider(error)
                isLoaded = true
                loadTask = nil
                onChange?()
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        keywordTemplateLoadTask?.cancel()
        keywordTemplateLoadTask = nil
        keywordCacheRevision &+= 1
        keywordTemplatesByID.removeAll()
        worker.flush()
    }

    func clearError() {
        guard errorMessage != nil else { return }
        errorMessage = nil
        onChange?()
    }

    func reloadAfterExternalDatabaseReset() {
        stop()
        items = []
        errorMessage = nil
        fatalErrorMessage = nil
        itemLoadErrorMessages.removeAll()
        isLoaded = false
        onChange?()
        start()
    }

    func retryLoading() {
        guard loadTask == nil else { return }
        items = []
        keywordTemplateLoadTask?.cancel()
        keywordTemplateLoadTask = nil
        keywordTemplatesByID.removeAll()
        errorMessage = nil
        fatalErrorMessage = nil
        itemLoadErrorMessages.removeAll()
        isLoaded = false
        onChange?()
        start()
    }

    func templateForKeywordExpansion(id: UUID) -> String? {
        keywordTemplatesByID[id]
    }

    func templateText(id: UUID) async -> String? {
        guard let item = items.first(where: { $0.id == id }), item.isSnippet else { return nil }
        if let templateText = item.templateText { return templateText }
        let payload = await loadPayload(for: item)
        guard !Task.isCancelled else { return nil }
        defer { item.discardCachedPayloadIfReloadable() }
        return payload?.plainText
    }

    func saveSnippet(_ draft: ClipboardSnippetDraft) async -> ClipboardSavedItem? {
        await withLibraryMutation {
            await self.saveSnippetLocked(draft)
        }
    }

    private func saveSnippetLocked(_ draft: ClipboardSnippetDraft) async -> ClipboardSavedItem? {
        guard isLoaded else { return nil }
        let now = Date()
        let existing = draft.id.flatMap { id in items.first { $0.id == id } }
        let snippetByteCount = draft.content.lengthOfBytes(using: .utf8)
        guard snippetByteCount <= ClipboardSavedItem.maximumSnippetUTF8ByteCount else {
            errorMessage = errorMessageProvider(ClipboardSavedLibraryError.snippetTooLarge(
                maximumByteCount: ClipboardSavedItem.maximumSnippetUTF8ByteCount
            ))
            onChange?()
            return nil
        }
        let trimmedKeyword = draft.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKeyword = ClipboardSavedItem.normalizedKeyword(draft.keyword)
        if let trimmedKeyword, !trimmedKeyword.isEmpty, normalizedKeyword == nil {
            errorMessage = errorMessageProvider(ClipboardSavedLibraryError.invalidKeyword)
            onChange?()
            return nil
        }
        if let normalizedKeyword,
           items.contains(where: {
               $0.id != existing?.id
                   && $0.keyword?.localizedCaseInsensitiveCompare(normalizedKeyword) == .orderedSame
           }) {
            errorMessage = errorMessageProvider(
                ClipboardSavedLibraryError.duplicateKeyword(normalizedKeyword)
            )
            onChange?()
            return nil
        }
        if normalizedKeyword != nil {
            let existingKeywordBytes = items.reduce(into: 0) { total, item in
                guard item.id != existing?.id, item.isSnippet, item.keyword != nil else { return }
                total += item.payloadByteCount
            }
            guard existingKeywordBytes + snippetByteCount
                <= ClipboardSavedItem.maximumKeywordExpansionCacheByteCount else {
                errorMessage = errorMessageProvider(
                    ClipboardSavedLibraryError.keywordExpansionCacheFull(
                        maximumByteCount: ClipboardSavedItem.maximumKeywordExpansionCacheByteCount
                    )
                )
                onChange?()
                return nil
            }
        }
        do {
            _ = try ClipboardSnippetTemplateEngine.expand(
                draft.content,
                context: .current(clipboardText: nil)
            )
        } catch {
            errorMessage = errorMessageProvider(error)
            onChange?()
            return nil
        }

        let reservedKeywordIdentity = normalizedKeyword.map(Self.keywordIdentity)
        if let reservedKeywordIdentity,
           reservedKeywordIdentities.contains(reservedKeywordIdentity) {
            errorMessage = errorMessageProvider(
                ClipboardSavedLibraryError.duplicateKeyword(normalizedKeyword ?? "")
            )
            onChange?()
            return nil
        }
        if let reservedKeywordIdentity {
            reservedKeywordIdentities.insert(reservedKeywordIdentity)
        }
        defer {
            if let reservedKeywordIdentity {
                reservedKeywordIdentities.remove(reservedKeywordIdentity)
            }
        }

        let draftPayload = ClipboardHistoryPayload.plainText(draft.content)
        let contentChanged = existing.map {
            $0.payloadDigest != ClipboardHistoryItem.digest(draftPayload)
        } ?? true
        let payloadChanged = existing == nil || contentChanged
        let item: ClipboardSavedItem
        if var existing, !contentChanged {
            existing.updateMetadata(
                title: draft.title,
                tags: draft.tags,
                keyword: normalizedKeyword,
                isFavorite: draft.isFavorite,
                templateText: draft.content,
                updatedAt: now
            )
            item = existing
        } else {
            item = ClipboardSavedItem(
                id: existing?.id ?? draft.id ?? UUID(),
                title: draft.title,
                tags: draft.tags,
                keyword: normalizedKeyword,
                isFavorite: draft.isFavorite,
                savedKind: .snippet,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastUsedAt: existing?.lastUsedAt,
                sourceApplication: existing?.sourceApplication,
                payload: draftPayload,
                templateText: draft.content
            )
        }
        guard await persistNewOrUpdated(item, payloadChanged: payloadChanged) else { return nil }
        reloadKeywordTemplateCache()
        return item
    }

    func toggleFavorite(id: UUID) async -> Bool {
        await withLibraryMutation {
            guard var item = self.items.first(where: { $0.id == id }) else { return false }
            item.updateFavorite(!item.isFavorite, updatedAt: Date())
            return await self.persistNewOrUpdated(item, payloadChanged: false)
        }
    }

    func updateMetadata(_ draft: ClipboardSavedMetadataDraft) async -> ClipboardSavedItem? {
        await withLibraryMutation {
            guard var item = self.items.first(where: { $0.id == draft.id }), !item.isSnippet else {
                return nil
            }
            item.updateMetadata(
                title: draft.title,
                tags: draft.tags,
                keyword: item.keyword,
                isFavorite: item.isFavorite,
                templateText: item.templateText,
                updatedAt: Date()
            )
            return await self.persistNewOrUpdated(item, payloadChanged: false) ? item : nil
        }
    }

    func delete(id: UUID) async -> Bool {
        await withLibraryMutation {
            guard self.items.contains(where: { $0.id == id }) else { return false }
            do {
                try await self.worker.delete(id: id)
                self.items.removeAll { $0.id == id }
                self.itemLoadErrorMessages.removeValue(forKey: id)
                self.keywordTemplatesByID.removeValue(forKey: id)
                self.reloadKeywordTemplateCache()
                self.onChange?()
                return true
            } catch {
                self.errorMessage = self.errorMessageProvider(error)
                self.onChange?()
                return false
            }
        }
    }

    func clearAll() async -> Bool {
        await withLibraryMutation {
            self.keywordCacheRevision &+= 1
            self.keywordTemplateLoadTask?.cancel()
            self.keywordTemplateLoadTask = nil
            do {
                try await self.worker.removeAll()
                self.items.removeAll()
                self.keywordTemplatesByID.removeAll()
                self.itemLoadErrorMessages.removeAll()
                self.errorMessage = nil
                self.fatalErrorMessage = nil
                self.onChange?()
                return true
            } catch {
                self.errorMessage = self.errorMessageProvider(error)
                self.onChange?()
                return false
            }
        }
    }

    func copy(id: UUID, asPlainText: Bool = false) async -> ClipboardSnippetExpansion? {
        await withLibraryMutation {
            await self.copyLocked(id: id, asPlainText: asPlainText)
        }
    }

    private func copyLocked(id: UUID, asPlainText: Bool) async -> ClipboardSnippetExpansion? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let payload = await loadPayload(for: item)
        guard let payload, !Task.isCancelled else { return nil }

        let expansion: ClipboardSnippetExpansion?
        if item.isSnippet, let template = payload.plainText {
            do {
                expansion = try ClipboardSnippetTemplateEngine.expand(
                    template,
                    context: .current(clipboardText: pasteboard.readPlainText())
                )
            } catch {
                errorMessage = errorMessageProvider(error)
                onChange?()
                return nil
            }
        } else {
            expansion = nil
        }

        let wrote: Bool
        if let expansion {
            wrote = pasteboard.writePlainText(expansion.text)
        } else if asPlainText {
            guard let text = ClipboardPlainTextConversion.text(for: item.historyPresentationItem()) else {
                errorMessage = errorMessageProvider(ClipboardSavedLibraryError.plainTextUnavailable)
                onChange?()
                return nil
            }
            wrote = pasteboard.writePlainText(text)
        } else {
            wrote = pasteboard.writePayload(payload)
        }
        guard wrote else { return nil }
        item.discardCachedPayloadIfReloadable()
        onPasteboardWrite?()

        if let index = items.firstIndex(where: { $0.id == id }) {
            let lastUsedAt = Date()
            do {
                try await worker.updateLastUsedAt(id: id, date: lastUsedAt)
                items[index].lastUsedAt = lastUsedAt
                items = ClipboardSavedLibrarySearch.sorted(items)
            } catch {
                errorMessage = errorMessageProvider(error)
            }
        }
        onChange?()
        return expansion ?? ClipboardSnippetExpansion(text: payload.plainText ?? "", cursorOffsetFromEnd: nil)
    }

    func matchingItems(query: String) -> [ClipboardSavedItem] {
        ClipboardSavedLibrarySearch.result(
            items: items,
            query: query,
            limit: max(items.count, 1)
        ).items
    }

    func draft(for id: UUID) async -> ClipboardSnippetDraft? {
        guard let item = items.first(where: { $0.id == id }), item.isSnippet,
              let content = await templateText(id: id) else { return nil }
        return ClipboardSnippetDraft(
            id: item.id,
            title: item.title,
            content: content,
            tags: item.tags,
            keyword: item.keyword,
            isFavorite: item.isFavorite
        )
    }

    func metadataDraft(for id: UUID) -> ClipboardSavedMetadataDraft? {
        guard let item = items.first(where: { $0.id == id }), !item.isSnippet else { return nil }
        return ClipboardSavedMetadataDraft(id: item.id, title: item.title, tags: item.tags)
    }

    func previewPayload(id: UUID) async -> ClipboardHistoryPayload? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        defer { item.discardCachedPayloadIfReloadable() }
        return await loadPayload(for: item)
    }

    func resolvedPlainText(id: UUID, expandsSnippet: Bool = true) async -> String? {
        guard let item = items.first(where: { $0.id == id }),
              let payload = await loadPayload(for: item),
              !Task.isCancelled else { return nil }
        defer { item.discardCachedPayloadIfReloadable() }
        if item.isSnippet, let template = payload.plainText {
            guard expandsSnippet else { return template }
            return try? ClipboardSnippetTemplateEngine.expand(
                template,
                context: .current(clipboardText: pasteboard.readPlainText())
            ).text
        }
        return ClipboardPlainTextConversion.text(for: item.historyPresentationItem())
    }

    func clearItemLoadError(id: UUID) {
        guard itemLoadErrorMessages.removeValue(forKey: id) != nil else { return }
        onChange?()
    }

    private func persistNewOrUpdated(
        _ item: ClipboardSavedItem,
        payloadChanged: Bool
    ) async -> Bool {
        do {
            try await worker.save(item, payloadChanged: payloadChanged)
            let reloadableItem = item.reloadingPayload(using: persistence)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = reloadableItem
            } else {
                items.append(reloadableItem)
            }
            items = ClipboardSavedLibrarySearch.sorted(items)
            errorMessage = nil
            onChange?()
            return true
        } catch {
            errorMessage = errorMessageProvider(error)
            onChange?()
            return false
        }
    }

    private func withLibraryMutation<Result>(
        operation: @MainActor () async -> Result
    ) async -> Result {
        await mutationGate.acquire()
        let result = await operation()
        await mutationGate.release()
        return result
    }

    private func reloadKeywordTemplateCache() {
        keywordCacheRevision &+= 1
        let revision = keywordCacheRevision
        keywordTemplateLoadTask?.cancel()
        let keywordItems = items.filter { $0.isSnippet && $0.keyword != nil }
        keywordTemplateLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var templates: [UUID: String] = [:]
            var totalByteCount = 0
            for item in keywordItems {
                guard !Task.isCancelled else { return }
                let payload = await self.loadPayload(for: item)
                item.discardCachedPayloadIfReloadable()
                guard !Task.isCancelled else { return }
                guard let template = payload?.plainText else { continue }
                let byteCount = template.lengthOfBytes(using: .utf8)
                guard byteCount <= ClipboardSavedItem.maximumSnippetUTF8ByteCount,
                      totalByteCount + byteCount
                        <= ClipboardSavedItem.maximumKeywordExpansionCacheByteCount else {
                    continue
                }
                templates[item.id] = template
                totalByteCount += byteCount
            }
            guard !Task.isCancelled, self.keywordCacheRevision == revision else { return }
            keywordTemplatesByID = templates
            keywordTemplateLoadTask = nil
            onChange?()
        }
    }

    private static func keywordIdentity(_ keyword: String) -> String {
        keyword.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func loadPayload(for item: ClipboardSavedItem) async -> ClipboardHistoryPayload? {
        do {
            let payload = try await item.loadPayloadAsync()
            if itemLoadErrorMessages.removeValue(forKey: item.id) != nil {
                onChange?()
            }
            return payload
        } catch is CancellationError {
            return nil
        } catch {
            itemLoadErrorMessages[item.id] = errorMessageProvider(error)
            onChange?()
            return nil
        }
    }

}
