import Foundation

/// Remembers each library asset's byte size so a rescan only reads resources
/// for assets that are new or edited. Reading them is the slow part of loading.
struct SizeCache: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let modified: Date?
        let size: Int64
        let filename: String
        let uti: String?
    }

    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }
    var ids: Set<String> { Set(entries.keys) }

    /// nil when absent or the asset changed since it was stored.
    func lookup(_ id: String, modified: Date?) -> Entry? {
        // No modification date means no way to tell the asset is unchanged.
        guard let modified, let entry = entries[id], entry.modified == modified else { return nil }
        return entry
    }

    mutating func store(_ id: String, modified: Date?, size: Int64, filename: String, uti: String?) {
        entries[id] = Entry(modified: modified, size: size, filename: filename, uti: uti)
    }

    mutating func prune(keeping: Set<String>) {
        entries = entries.filter { keeping.contains($0.key) }
    }

    /// Only this kind's entries, so a scan never writes back a stale copy of the other's.
    func entries(withPrefix prefix: String) -> SizeCache {
        var out = SizeCache()
        out.entries = entries.filter { $0.key.hasPrefix(prefix) }
        return out
    }

    /// Pruning against a limited-access or empty fetch would delete sizes for
    /// assets that still exist but are merely hidden from this scan.
    static func shouldPrune(authorizationLimited: Bool, total: Int) -> Bool {
        !authorizationLimited && total > 0
    }

    mutating func merge(_ other: SizeCache) {
        entries.merge(other.entries) { _, new in new }
    }

    /// Cached entry on a hit; otherwise `read` runs once. Only a MEASURED size
    /// of an asset with a modification date is stored: a guess cached under an
    /// unchanged date would be reused on every later scan.
    mutating func resolve(_ id: String, modified: Date?,
                          read: () -> (size: Int64, filename: String, uti: String?, measured: Bool))
        -> (entry: Entry, hit: Bool) {
        if let entry = lookup(id, modified: modified) { return (entry, true) }
        let r = read()
        if r.measured, modified != nil {
            store(id, modified: modified, size: r.size, filename: r.filename, uti: r.uti)
        }
        return (Entry(modified: modified, size: r.size, filename: r.filename, uti: r.uti), false)
    }

    func save(to url: URL) throws {
        let data = try PropertyListEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Missing or corrupt file gives an empty cache: a rescan, never a crash.
    static func load(from url: URL) -> SizeCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(SizeCache.self, from: data)
        else { return SizeCache() }
        return cache
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("size-cache.plist")
    }
}
