import Darwin
import Foundation

/// One raw attribute entry returned by `getattrlistbulk`. Missing fields are nil—non-APFS volumes may omit attributes,
/// so the parser must not assume a fixed layout (design §3.3).
public struct FileSystemBulkAttributeEntry: Equatable, Sendable {
    /// Entry name as **raw NUL-terminated bytes**.
    ///
    /// File names are not guaranteed to be valid UTF-8 (HFS+ / external volumes / FUSE may produce illegal sequences).
    /// Converting to String then back for `openat`/`fstatat` can drop bytes, fail descent, and be misreported as walkError,
    /// so keep raw bytes and only lossily convert for display.
    public var nameBytes: [CChar]?
    public var fileType: FileSystemEntryType?
    public var devid: UInt64?
    public var fileID: UInt64?
    public var linkCount: UInt32?
    public var dataLength: Int64?
    public var allocatedSize: Int64?
    public var modificationDate: Date?
    public var flags: UInt32?

    public init() {}
    /// true = fixed-section end does not match `ATTR_CMN_NAME`'s `attr_dataoffset`.
    ///
    /// See the layout-check notes on `FileSystemBulkAttributeParser`. When set, every attribute except `nameBytes`
    /// is untrustworthy; the caller must fall back to per-entry `fstatat`.
    public var hasLayoutMismatch: Bool = false

    public var displayName: String? {
        guard let nameBytes else { return nil }
        let bytes = nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether required attributes are present. Directories omit `ATTR_FILE_*`, so missing linkCount/dataLength is allowed for them.
    public var isFullyResolved: Bool {
        guard !hasLayoutMismatch, nameBytes != nil, let fileType, devid != nil, fileID != nil else {
            return false
        }
        if fileType == .directory {
            return true
        }
        return linkCount != nil && dataLength != nil
    }
}

public struct FileSystemBulkAttributeParseResult: Equatable, Sendable {
    public let entries: [FileSystemBulkAttributeEntry]
    /// Buffer structure was abnormal and parsing stopped early: fewer entries than the kernel declared.
    public let isTruncated: Bool
}

/// `getattrlistbulk` buffer parser.
///
/// **Layout facts (verified against the kernel; do not infer from the man page alone):**
/// 1. Fixed fields inside an entry are packed in ascending attribute-bit order with no alignment padding, so reads must be unaligned.
/// 2. `RETURNED_ATTRS` is always the first field (immediately after the 4-byte entry length).
/// 3. Requested-but-not-returned attributes do **not** always vanish from the buffer: directory entries truly omit `ATTR_FILE_*`,
///    but `ATTR_CMN_ERROR` still occupies 4 bytes even when its returned bit is 0. This parser therefore
///    **does not request `ATTR_CMN_ERROR`**—skipping it via the bitmap would misalign every following field.
///    Per-entry failure detection is left to the caller's `fstatat` fallback (strictly more informative).
/// 4. To defend against similar unknown "reserved but not flagged" behavior, after the fixed section we re-check bounds using `ATTR_CMN_NAME`'s
///    `attr_dataoffset` (start of the variable section, independent of the bitmap); on mismatch set
///    `hasLayoutMismatch`, turning silent misalignment into a detectable safe fallback.
public enum FileSystemBulkAttributeParser {
    public static let requestedCommonAttributes: attrgroup_t =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_FILEID)

    public static let requestedFileAttributes: attrgroup_t =
        attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_DATALENGTH)

    /// Indexes of the kernel-returned attribute bitmaps in `attribute_set_t`: common/vol/dir/file/fork.
    private static let commonGroupIndex = 0
    private static let fileGroupIndex = 3
    private static let returnedAttributesSize = 20

    public static func makeAttributeList(includeStorageDetails: Bool = false) -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = requestedCommonAttributes
        list.fileattr = requestedFileAttributes
        if includeStorageDetails {
            list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
            list.fileattr |= attrgroup_t(ATTR_FILE_ALLOCSIZE)
        }
        return list
    }

    public static func parse(
        buffer: UnsafeRawBufferPointer,
        entryCount: Int
    ) -> FileSystemBulkAttributeParseResult {
        guard entryCount > 0 else {
            return FileSystemBulkAttributeParseResult(entries: [], isTruncated: false)
        }

        var entries: [FileSystemBulkAttributeEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0

        for _ in 0..<entryCount {
            guard cursor + 4 <= buffer.count else {
                return FileSystemBulkAttributeParseResult(entries: entries, isTruncated: true)
            }
            let entryLength = Int(buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
            guard entryLength >= 4, cursor + entryLength <= buffer.count else {
                return FileSystemBulkAttributeParseResult(entries: entries, isTruncated: true)
            }

            entries.append(
                parseEntry(
                    buffer: UnsafeRawBufferPointer(rebasing: buffer[cursor..<(cursor + entryLength)])
                )
            )
            cursor += entryLength
        }

        return FileSystemBulkAttributeParseResult(entries: entries, isTruncated: false)
    }

    private static func parseEntry(buffer: UnsafeRawBufferPointer) -> FileSystemBulkAttributeEntry {
        var entry = FileSystemBulkAttributeEntry()

        // The 4-byte entry length + 20-byte RETURNED_ATTRS are prerequisites for any further parsing.
        guard buffer.count >= 4 + returnedAttributesSize else {
            entry.hasLayoutMismatch = true
            return entry
        }

        let commonReturned = buffer.loadUnaligned(
            fromByteOffset: 4 + commonGroupIndex * 4,
            as: attrgroup_t.self
        )
        let fileReturned = buffer.loadUnaligned(
            fromByteOffset: 4 + fileGroupIndex * 4,
            as: attrgroup_t.self
        )

        var reader = Reader(buffer: buffer, offset: 4 + returnedAttributesSize)
        var expectedNameDataOffset: Int?

        if commonReturned & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let referenceOffset = reader.offset
            guard let dataOffset = reader.readInt32(), let length = reader.readUInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            let nameDataOffset = referenceOffset + Int(dataOffset)
            expectedNameDataOffset = nameDataOffset
            entry.nameBytes = readName(buffer: buffer, offset: nameDataOffset, length: Int(length))
        }

        if commonReturned & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            guard let value = reader.readInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.devid = UInt64(UInt32(bitPattern: value))
        }

        if commonReturned & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            guard let value = reader.readUInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.fileType = fileType(objectType: value)
        }

        if commonReturned & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            guard let seconds = reader.readInt64(), let nanos = reader.readInt64() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.modificationDate = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        }
        if commonReturned & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            guard let flags = reader.readUInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.flags = flags
        }

        if commonReturned & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            guard let value = reader.readUInt64() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.fileID = value
        }

        if fileReturned & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            guard let value = reader.readUInt32() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.linkCount = value
        }

        if fileReturned & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            guard let allocated = reader.readInt64() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.allocatedSize = allocated
        }

        if fileReturned & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            guard let value = reader.readInt64() else {
                entry.hasLayoutMismatch = true
                return entry
            }
            entry.dataLength = value
        }

        // The fixed-section end must be exactly the start of the variable section (NAME is the only variable field); otherwise there are
        // attributes that occupy space without being declared in the bitmap, and every later field is misaligned.
        if let expectedNameDataOffset, reader.offset != expectedNameDataOffset {
            entry.hasLayoutMismatch = true
            entry.fileType = nil
            entry.devid = nil
            entry.fileID = nil
            entry.linkCount = nil
            entry.dataLength = nil
        }

        return entry
    }

    private static func readName(
        buffer: UnsafeRawBufferPointer,
        offset: Int,
        length: Int
    ) -> [CChar]? {
        guard offset >= 0, length > 0, offset < buffer.count else { return nil }
        let available = min(length, buffer.count - offset)
        var bytes: [CChar] = []
        bytes.reserveCapacity(available)
        for index in 0..<available {
            let byte = buffer.loadUnaligned(fromByteOffset: offset + index, as: UInt8.self)
            if byte == 0 { break }
            bytes.append(CChar(bitPattern: byte))
        }
        guard !bytes.isEmpty else { return nil }
        bytes.append(0)
        return bytes
    }

    private static func fileType(objectType: UInt32) -> FileSystemEntryType {
        switch objectType {
        case UInt32(VDIR.rawValue): return .directory
        case UInt32(VREG.rawValue): return .regularFile
        case UInt32(VLNK.rawValue): return .symlink
        default: return .other
        }
    }

    /// Bounds-checked unaligned cursor: out-of-range reads return nil so the caller can set `hasLayoutMismatch`.
    private struct Reader {
        let buffer: UnsafeRawBufferPointer
        var offset: Int

        mutating func readInt32() -> Int32? { read(as: Int32.self) }
        mutating func readUInt32() -> UInt32? { read(as: UInt32.self) }
        mutating func readInt64() -> Int64? { read(as: Int64.self) }
        mutating func readUInt64() -> UInt64? { read(as: UInt64.self) }

        private mutating func read<T>(as type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset >= 0, offset + size <= buffer.count else { return nil }
            let value = buffer.loadUnaligned(fromByteOffset: offset, as: type)
            offset += size
            return value
        }
    }
}
