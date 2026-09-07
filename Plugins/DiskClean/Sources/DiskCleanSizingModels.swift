import Darwin
import MacToolsFileSystem
import Foundation

/// Completeness of a sizing result.
///
/// Core invariant (design §3.1): candidates with `completeness != .complete`, or with
/// `crossedMountPoint` in the reason set, are **not cleanable**. The selection model,
/// Planner, and executor each recheck; this type only records degradation reasons honestly.
enum DiskCleanScanCompleteness: Equatable, Sendable {
    case complete
    case partial(reasons: Set<PartialReason>)

    enum PartialReason: Equatable, Sendable, Hashable {
        /// Cooperative deadline expired, or the caller cancelled.
        case timedOut
        /// EPERM/EACCES subtree was skipped.
        case permissionDenied
        /// Non-local volume, blacklisted volume, or sizing not run after circuit break.
        case unsupportedVolume
        /// Mount point found in the subtree; did not descend.
        case crossedMountPoint
        /// Attribute anomaly and per-entry fstatat fallback failed.
        case walkError
    }

    var isComplete: Bool {
        self == .complete
    }

    var partialReasons: Set<PartialReason> {
        guard case let .partial(reasons) = self else { return [] }
        return reasons
    }
}

/// Root object identity. Used for size-cache hit checks and pre-execution fd-anchored revalidation.
struct DiskCleanRootIdentity: Equatable, Sendable {
    /// File type. Design §3.1 lists directory/regularFile/symlink; `other` covers sockets,
    /// FIFOs, and device nodes that really appear in cache directories — they must be
    /// classified honestly rather than forced into regular-file shape.
    typealias FileType = FileSystemEntryType

    /// `st_dev`. Mount guards and the device blacklist both use this value.
    let devid: UInt64
    /// `st_ino`。
    let fileID: UInt64
    let mtime: Date
    let fileType: FileType

    /// Build identity from `stat`.
    init(stat value: stat) {
        self.devid = UInt64(UInt32(bitPattern: value.st_dev))
        self.fileID = value.st_ino
        self.mtime = Self.date(from: value.st_mtimespec)
        self.fileType = FileType(mode: value.st_mode)
    }

    init(devid: UInt64, fileID: UInt64, mtime: Date, fileType: FileType) {
        self.devid = devid
        self.fileID = fileID
        self.mtime = mtime
        self.fileType = fileType
    }

    /// Time conversion lives in one place: cache hits require exact mtime equality, so both sides must use the same conversion.
    static func date(from time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}

extension DiskCleanRootIdentity.FileType {
    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFDIR: self = .directory
        case S_IFREG: self = .regularFile
        case S_IFLNK: self = .symlink
        default: self = .other
        }
    }
}

struct DiskCleanSizeResult: Equatable, Sendable {
    /// Estimated logical size (`st_size` sum; hard links deduped by `(devid, fileID)`).
    ///
    /// Not the same as reclaimable space: APFS clones, sparse files, and hard links outside
    /// the tree make them differ. UI always says "about X GB"; completion copy must not say "freed".
    let estimatedBytes: Int64
    let fileCount: Int
    let completeness: DiskCleanScanCompleteness
    /// `fstat` of the root fd. nil only when the root cannot be opened at all (or is blocked by
    /// circuit break / blacklist); then `completeness` is never `.complete` and the candidate is not cleanable.
    let rootIdentity: DiskCleanRootIdentity?
    /// True observation time. On cache hits, propagate the entry's observedAt; never refresh it to read time.
    let observedAt: Date

    init(
        estimatedBytes: Int64,
        fileCount: Int,
        completeness: DiskCleanScanCompleteness,
        rootIdentity: DiskCleanRootIdentity?,
        observedAt: Date
    ) {
        self.estimatedBytes = estimatedBytes
        self.fileCount = fileCount
        self.completeness = completeness
        self.rootIdentity = rootIdentity
        self.observedAt = observedAt
    }

    /// Result when no size information could be obtained.
    static func unavailable(
        reasons: Set<DiskCleanScanCompleteness.PartialReason>,
        rootIdentity: DiskCleanRootIdentity? = nil,
        observedAt: Date
    ) -> DiskCleanSizeResult {
        DiskCleanSizeResult(
            estimatedBytes: 0,
            fileCount: 0,
            completeness: .partial(reasons: reasons),
            rootIdentity: rootIdentity,
            observedAt: observedAt
        )
    }
}

/// Collect degradation reasons along the way so every branch does not rebuild the Set.
struct DiskCleanCompletenessAccumulator {
    private var reasons: Set<DiskCleanScanCompleteness.PartialReason> = []

    mutating func add(_ reason: DiskCleanScanCompleteness.PartialReason) {
        reasons.insert(reason)
    }

    /// Map errno to a degradation reason: permission cases are separate; everything else is walkError.
    mutating func add(errno code: Int32) {
        add(code == EPERM || code == EACCES ? .permissionDenied : .walkError)
    }

    var completeness: DiskCleanScanCompleteness {
        reasons.isEmpty ? .complete : .partial(reasons: reasons)
    }
}

/// Runtime context for a blocking sizer.
///
/// Cancel and timeout are one exit for the walker: both make traversal return ASAP and
/// mark the result `.timedOut` (callers discard the result on cancel).
struct DiskCleanSizingContext: Sendable {
    let deadline: Date
    let isCancelled: @Sendable () -> Bool
    /// Called **immediately** after the sizer opens the root fd to report the root's device id.
    ///
    /// false means the device is on the circuit-break blacklist; the sizer must abandon at once
    /// and return `partial([.unsupportedVolume])`. The report itself lets WorkerPool know which
    /// device to blacklist when it abandons a timed-out thread.
    let admitDevice: @Sendable (UInt64) -> Bool
    /// Injectable clock for testing deadline checks.
    let now: @Sendable () -> Date

    init(
        deadline: Date,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        admitDevice: @escaping @Sendable (UInt64) -> Bool = { _ in true },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deadline = deadline
        self.isCancelled = isCancelled
        self.admitDevice = admitDevice
        self.now = now
    }

    /// Whether traversal should stop (cancelled or deadline passed).
    var shouldStop: Bool {
        isCancelled() || now() >= deadline
    }
}

/// Sizing capability. **Blocking**: implementations may stall in syscalls and must be
/// invoked on resident `DiskCleanWorkerPool` threads, never directly on the Swift concurrency pool.
protocol DiskCleanDirectorySizing: Sendable {
    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult
}
