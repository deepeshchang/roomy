import Foundation

/// What the library grid needs from a video or a photo to sort and filter it.
protocol LibraryEntry: Identifiable where ID == String {
    var fileSize: Int64 { get }
    var creationDate: Date? { get }
    var looksAlreadyCompressed: Bool { get }
}

extension LibraryVideo: LibraryEntry {}
extension LibraryPhoto: LibraryEntry {}

enum LibrarySort: String, Sendable { case largest, newest }

/// The library's sort and filters (library-v2 spec §2.4). Combined as AND
/// under one sort. Pure, so the grid, the results line and the tests agree.
struct LibraryQuery: Equatable, Sendable {
    var sort: LibrarySort = .largest
    /// 0 = All. Items at or over this size are shown.
    var minBytes: Int64 = 0
    /// Off by default: on hid whole WhatsApp-heavy libraries (QA B4).
    var hideCompressed = false

    var isFiltered: Bool { minBytes > 0 || hideCompressed }

    static func isCompressed(_ item: some LibraryEntry, handled: Set<String>) -> Bool {
        handled.contains(item.id) || item.looksAlreadyCompressed
    }

    func apply<T: LibraryEntry>(_ items: [T], handled: Set<String>) -> [T] {
        let kept = items.filter {
            $0.fileSize >= minBytes && !(hideCompressed && Self.isCompressed($0, handled: handled))
        }
        switch sort {
        case .largest: return kept.sorted { $0.fileSize > $1.fileSize }
        case .newest: return kept.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        }
    }

    /// Fixed presets, different per type (PRD §2).
    static func sizeOptions(for kind: MediaKind) -> [Int64] {
        kind == .video ? [0, 100_000_000, 500_000_000, 1_000_000_000] : [0, 5_000_000, 10_000_000]
    }

    /// The N largest not-yet-compressed items. Ignores the size filter and
    /// the sort, so the card always shows the real top N.
    static func biggestWins<T: LibraryEntry>(_ items: [T], handled: Set<String>, count: Int = 20) -> [T] {
        Array(items.filter { !isCompressed($0, handled: handled) }
            .sorted { $0.fileSize > $1.fileSize }
            .prefix(count))
    }

    /// Smallest size still in the top 10% (rounded up, so the biggest item
    /// of a short list counts). `.max` when there is nothing.
    static func largeCutoff(_ sizes: [Int64]) -> Int64 {
        guard !sizes.isEmpty else { return .max }
        let top = (sizes.count + 9) / 10
        return sizes.sorted(by: >)[top - 1]
    }

    static func isLarge(_ bytes: Int64, cutoff: Int64) -> Bool {
        bytes >= 1_000_000_000 || bytes >= cutoff
    }
}
