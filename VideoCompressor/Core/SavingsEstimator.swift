import Foundation

struct SavingsEstimate: Sendable, Equatable {
    let estimatedBytes: Int64
    let savedBytes: Int64
    let savedFraction: Double
    let isWorthwhile: Bool

    var formattedSaving: String {
        guard savedBytes > 0 else { return "No saving" }
        let size = ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
        return "Saves \(size) (\(Int(savedFraction * 100))%)"
    }
}

enum SavingsEstimator {
    /// Below this fraction, compressing is not worth the battery or the wait.
    static let worthwhileThreshold = 0.10

    /// The plan knows the exact bitrate and duration it will encode at, so the
    /// estimate is arithmetic rather than a guess from a ratio table.
    static func estimate(for metadata: VideoMetadata, plan: CompressionPlan) -> SavingsEstimate {
        let source = metadata.fileSize
        let estimated = plan.estimatedBytes
        let saved = max(0, source - estimated)
        let fraction = source > 0 ? Double(saved) / Double(source) : 0

        return SavingsEstimate(estimatedBytes: estimated,
                               savedBytes: saved,
                               savedFraction: fraction,
                               isWorthwhile: fraction >= worthwhileThreshold)
    }
}
