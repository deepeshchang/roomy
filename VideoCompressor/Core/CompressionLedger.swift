import Foundation

/// Remembers which library videos this app has already dealt with, so they
/// stop showing up as candidates.
///
/// Records both sides of every successful save: the new compressed asset (so
/// it is never re-compressed) and the original it came from (so it is not
/// offered again while it waits to be deleted).
///
/// UserDefaults, keyed by PHAsset localIdentifier. Identifiers are
/// per-device and the list is lost on uninstall; the bitrate check in
/// LibraryVideo covers anything this misses. Move to a file if it ever holds
/// tens of thousands of IDs.
struct CompressionLedger {
    private let defaults: UserDefaults
    private static let key = "compressionLedger.handledAssetIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var handledIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func record(original: String?, compressed: String?) {
        var ids = handledIDs
        if let original { ids.insert(original) }
        if let compressed { ids.insert(compressed) }
        defaults.set(Array(ids), forKey: Self.key)
    }
}
