import Foundation

/// The Library's selection across both segments. Asset IDs are unique across
/// videos and photos, so one set holds both and switching segments never
/// clears anything.
///
/// Bulk operations take the *visible, largest-first* list of the current
/// segment and only ever touch IDs in it.
struct LibrarySelection: Equatable, Sendable {
    typealias Item = (id: String, bytes: Int64)

    var ids: Set<String> = []

    mutating func toggle(_ id: String) {
        if ids.remove(id) == nil { ids.insert(id) }
    }

    /// "Top N" replaces this segment's selection with its N biggest items.
    mutating func selectTop(_ n: Int, of visible: [Item]) {
        replace(in: visible, with: visible.prefix(n).map(\.id))
    }

    mutating func selectOver(_ bytes: Int64, of visible: [Item]) {
        replace(in: visible, with: visible.filter { $0.bytes > bytes }.map(\.id))
    }

    /// Range select: adds `id` and everything after it (smaller), keeps the rest.
    mutating func selectFrom(_ id: String, of visible: [Item]) {
        guard let start = visible.firstIndex(where: { $0.id == id }) else { return }
        ids.formUnion(visible[start...].map(\.id))
    }

    mutating func deselectAll() { ids.removeAll() }

    /// Drag-to-select, recomputed from the selection as it was when the drag
    /// began (`base`), so moving the finger back un-does what it passed over.
    /// Like Photos: starting on a selected cell deselects the range, starting
    /// on an unselected one selects it.
    mutating func drag(from startID: String, to currentID: String,
                       in visible: [Item], base: Set<String>) {
        guard let a = visible.firstIndex(where: { $0.id == startID }),
              let b = visible.firstIndex(where: { $0.id == currentID }) else { return }
        let range = Set(visible[min(a, b)...max(a, b)].map(\.id))
        ids = base.contains(startID) ? base.subtracting(range) : base.union(range)
    }

    /// Drops selected IDs that are no longer visible. Returns how many went.
    @discardableResult
    mutating func prune(keeping visible: Set<String>) -> Int {
        let before = ids.count
        ids.formIntersection(visible)
        return before - ids.count
    }

    private mutating func replace(in visible: [Item], with chosen: [String]) {
        ids.subtract(visible.map(\.id))
        ids.formUnion(chosen)
    }

    /// Bytes the selection would free: the same plans the batch will run.
    static func estimatedFreed(videos: [LibraryVideo], photos: [LibraryPhoto],
                               settings: CompressionSettings) -> Int64 {
        let v = videos.reduce(Int64(0)) { sum, video in
            let meta = video.placeholderMetadata
            return sum + SavingsEstimator.estimate(
                for: meta, plan: settings.videoPlan(for: meta)).savedBytes
        }
        let p = photos.reduce(Int64(0)) {
            $0 + max(0, $1.fileSize - settings.photoPlan(for: $1).estimatedBytes)
        }
        return v + p
    }
}
