import Foundation

/// Time remaining for a batch, from overall progress and elapsed time.
///
/// Honest by construction: no estimate until there is enough to go on, and a
/// reading that swings more than 50% from the last one is suppressed rather
/// than shown — a tiny clip after a huge one would otherwise flash a number
/// that is wrong by an order of magnitude.
struct ETAEstimator: Sendable {
    private(set) var last: TimeInterval?

    static let minimumFraction = 0.03
    static let minimumElapsed: TimeInterval = 3
    static let maximumSwing = 0.5

    mutating func update(fraction: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard fraction >= Self.minimumFraction, fraction < 1,
              elapsed >= Self.minimumElapsed else { return nil }
        let estimate = elapsed * (1 - fraction) / fraction
        defer { last = estimate }
        if let last, last > 0, abs(estimate - last) / last > Self.maximumSwing { return nil }
        return estimate
    }

    static func text(for seconds: TimeInterval) -> String {
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "About \(minutes) min left" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "About \(hours) hr left" : "About \(hours) hr \(rest) min left"
    }
}
