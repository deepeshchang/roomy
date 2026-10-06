import Foundation

/// Combines the video and photo scan progress streams into one fraction + label,
/// and decides when the progress UI is worth showing.
struct LoadProgress {
    var videos: (scanned: Int, total: Int) = (0, 0)
    var photos: (scanned: Int, total: Int) = (0, 0)

    /// Warm-cache scans finish well inside this; showing progress sooner would only flash.
    static let showDelay: TimeInterval = 0.3

    static func shouldShow(elapsed: TimeInterval) -> Bool { elapsed >= showDelay }

    var scanned: Int { videos.scanned + photos.scanned }
    var total: Int { videos.total + photos.total }
    var fraction: Double { total > 0 ? min(1, Double(scanned) / Double(total)) : 0 }
    var label: String {
        total > 0 ? "Reading sizes… \(scanned.formatted()) of \(total.formatted())" : "Reading sizes…"
    }
}

/// Tags each library load so a superseded (stale) load can't write its results over a newer one.
struct LoadGeneration {
    private var current = 0
    mutating func begin() -> Int { current += 1; return current }
    func isCurrent(_ id: Int) -> Bool { id == current }
}
