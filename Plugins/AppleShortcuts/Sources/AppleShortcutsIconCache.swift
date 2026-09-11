import Foundation

/// A memory-pressure-aware cache for Apple Shortcuts icon bitmaps.
///
/// Icon bytes are intentionally kept out of `AppleShortcutItem`/`AppleShortcutVisualMetadata`
/// because they are only needed while the settings workspace is visible; storing them in the
/// cache instead of the discovery snapshot keeps that snapshot cheap to copy and lets callers
/// discard every cached icon in one step when the settings page closes.
@MainActor
final class AppleShortcutsIconCache {
    /// Icons are downscaled and re-encoded before being cached (see
    /// `AppleShortcutsVisualMetadataLoader`), so this advisory budget should comfortably cover the
    /// settings list. `NSCache` may temporarily exceed its total-cost limit; cached icons are
    /// removed explicitly when the settings workspace closes.
    static let defaultTotalCostLimit = 16 * 1_024 * 1_024

    private let cache: NSCache<NSUUID, NSData>

    // Inject storage for deterministic tests; production keeps NSCache's automatic eviction.
    init(
        totalCostLimit: Int = AppleShortcutsIconCache.defaultTotalCostLimit,
        cache: NSCache<NSUUID, NSData> = NSCache()
    ) {
        self.cache = cache
        cache.totalCostLimit = totalCostLimit
    }

    func data(for shortcutID: UUID) -> Data? {
        cache.object(forKey: shortcutID as NSUUID) as Data?
    }

    func store(_ data: Data, for shortcutID: UUID) {
        cache.setObject(data as NSData, forKey: shortcutID as NSUUID, cost: data.count)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
