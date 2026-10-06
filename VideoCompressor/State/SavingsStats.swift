import Foundation

/// Lifetime savings (PRD §4). "Saved" counts only originals iOS confirmed
/// deleted through Roomy; compressed-but-not-deleted items are "ready to free".
///
/// JSON in UserDefaults, local only. iCloud KVS needs an
/// entitlement free Personal Team signing can't have, so the total resets on
/// uninstall. Move to iCloud KVS if the app ever ships with a paid team.
struct SavingsStats: Codable, Equatable, Sendable {
    struct Ready: Codable, Equatable, Sendable {
        var kind: MediaKind
        var bytes: Int64
        /// localIdentifier of the compressed copy. Optional so data saved
        /// before it was recorded still decodes; such entries are never deleted.
        var copyID: String?
    }

    var savedBytes: Int64 = 0
    var videoCount = 0
    var photoCount = 0
    var lastBatchBytes: Int64 = 0
    var lastBatchDate: Date?
    /// Original asset ID → what deleting it would free.
    var ready: [String: Ready] = [:]

    var readyBytes: Int64 { ready.values.reduce(0) { $0 + $1.bytes } }
    var readyIDs: Set<String> { Set(ready.keys) }

    /// A copy that isn't smaller adds nothing (never zero or negative), and a
    /// copy PhotoKit gave no ID for can't be proven to exist, so it adds nothing.
    mutating func recordCompressed(id: String, kind: MediaKind, savedBytes bytes: Int64,
                                   copyID: String?) {
        guard bytes > 0, let copyID else { return }
        ready[id] = Ready(kind: kind, bytes: bytes, copyID: copyID)
    }

    /// Drop originals from "ready" without counting them as saved.
    mutating func drop(ids: [String]) {
        for id in ids { ready.removeValue(forKey: id) }
    }

    /// THE delete gate. Given original ID → copy ID and the copy IDs PhotoKit
    /// just confirmed exist: only originals whose copy exists are safe; the
    /// rest (copy gone, or never known) must be dropped and never deleted.
    static func deletionPlan(copies: [String: String?],
                             existing: Set<String>) -> (safe: [String], drop: [String]) {
        var safe: [String] = [], drop: [String] = []
        for (original, copy) in copies {
            if let copy, existing.contains(copy) { safe.append(original) } else { drop.append(original) }
        }
        return (safe.sorted(), drop.sorted())
    }

    /// iOS confirmed these originals deleted. Only IDs we compressed count,
    /// and each only once.
    mutating func recordDeleted(ids: [String], on date: Date = .now) {
        var batch: Int64 = 0
        for id in ids {
            guard let item = ready.removeValue(forKey: id) else { continue }
            batch += item.bytes
            if item.kind == .video { videoCount += 1 } else { photoCount += 1 }
        }
        guard batch > 0 else { return }
        savedBytes += batch
        lastBatchBytes = batch
        lastBatchDate = date
    }

    /// Originals that vanished without a delete through Roomy: dropped, not counted.
    mutating func prune(keeping existing: Set<String>) {
        ready = ready.filter { existing.contains($0.key) }
    }

    // MARK: Storage

    static let key = "savingsStats"

    static func load(_ defaults: UserDefaults = .standard) -> SavingsStats {
        decode(defaults.data(forKey: key))
    }

    static func decode(_ data: Data?) -> SavingsStats {
        data.flatMap { try? JSONDecoder().decode(SavingsStats.self, from: $0) } ?? SavingsStats()
    }

    static func update(_ defaults: UserDefaults = .standard, _ change: (inout SavingsStats) -> Void) {
        var stats = load(defaults)
        change(&stats)
        defaults.set(try? JSONEncoder().encode(stats), forKey: key)
    }

    static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
