import AppKit
import Foundation
import os

// MARK: - Probe seam

/// Full Disk Access probe (design §9).
///
/// The capability probe remains plugin-owned so the scan engine, contextual warnings, and
/// host-rendered permission card share one cached result for the lifetime of the process.
protocol DiskCleanFullDiskAccessProbing: Sendable {
    var hasFullDiskAccess: Bool { get }
}

/// Always reports authorized. Default for scan-engine tests so no target is skipped and
/// coverage matches v1 entry-for-entry.
struct DiskCleanAssumedFullDiskAccess: DiskCleanFullDiskAccessProbing {
    var hasFullDiskAccess: Bool { true }
}

/// Whether a single file can be opened read-only. Boundary between the real probe and test doubles.
protocol DiskCleanFileReadabilityProbing: Sendable {
    func canOpenForReading(atPath path: String) -> Bool
}

/// `FileHandle(forReadingAtPath:)`: **open then immediately close; read no bytes**.
///
/// Prefer `FileHandle` over `open(2)`: probe targets are TCC-protected files, and Foundation's
/// silent failure ("return nil if it cannot open") is exactly what we want—no throw, no log,
/// no user-visible side effect.
struct DiskCleanFileHandleReadabilityProbe: DiskCleanFileReadabilityProbing {
    func canOpenForReading(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }
}

// MARK: - Capability probe

/// Full Disk Access capability probe (design §9).
///
/// **There is no FDA query API**, so try opening a known protected file: openable = has FDA.
/// The probe itself must never present a prompt—FDA-class protection is silent EPERM; only
/// Documents/Downloads/Desktop and sandbox containers (`kTCCServiceSystemPolicyAppData`) prompt,
/// and those are deliberately avoided here.
///
/// **Process-local cache**: FDA is bound at process launch and does not change while running—
/// which is why the status card tells users to quit and reopen. The cache also ensures every
/// target in the same scan sees the same answer.
final class DiskCleanFullDiskAccessProbe: DiskCleanFullDiskAccessProbing, @unchecked Sendable {
    /// Process-wide shared instance. Scan engine and detail page read the same result so they
    /// never disagree ("engine says no, UI says yes").
    static let shared = DiskCleanFullDiskAccessProbe()

    /// Probe targets, tried in order; first successful open wins.
    ///
    /// - TCC.db: present on any account that has made a privacy decision; broadest coverage and
    ///   pure FDA-class protection.
    /// - Safari bookmarks: fallback if TCC.db is missing (e.g. brand-new account). Same silent
    ///   EPERM class.
    ///
    /// If both fail to open, report unauthorized. Missing file and denial are treated the same:
    /// neither proves FDA. A false positive would let the engine expand protected targets and
    /// produce a pile of empty permissionDenied candidates.
    static func defaultProbePaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [
            homeDirectory + "/Library/Application Support/com.apple.TCC/TCC.db",
            homeDirectory + "/Library/Safari/Bookmarks.plist"
        ]
    }

    private let probePaths: [String]
    private let readability: any DiskCleanFileReadabilityProbing
    private let cachedResult = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    init(
        probePaths: [String] = DiskCleanFullDiskAccessProbe.defaultProbePaths(),
        readability: any DiskCleanFileReadabilityProbing = DiskCleanFileHandleReadabilityProbe()
    ) {
        self.probePaths = probePaths
        self.readability = readability
    }

    var hasFullDiskAccess: Bool {
        if let cached = cachedResult.withLock({ $0 }) {
            return cached
        }
        // Evaluate outside the lock: probing is a filesystem call; holding the lock would make
        // concurrent sizing threads queue on a single open. Concurrent first visits may probe
        // once extra at most; results are identical and side-effect free.
        let result = probePaths.contains { readability.canOpenForReading(atPath: $0) }
        cachedResult.withLock { $0 = result }
        return result
    }
}

// MARK: - Authorization guide

/// Destination for "Open Settings" (design §9).
enum DiskCleanFullDiskAccessGuide {
    /// System Settings → Privacy & Security → Full Disk Access.
    static let settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    static var settingsURL: URL? {
        URL(string: settingsURLString)
    }

    /// Open System Settings. Silently return if URL construction fails—a no-op button is better than a crash.
    @MainActor
    static func openSettings() {
        guard let settingsURL else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
