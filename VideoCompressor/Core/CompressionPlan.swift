import Foundation

/// How big a compressed copy is allowed to be.
enum TargetSize: Int, CaseIterable, Identifiable, Sendable, Codable {
    case mb50 = 50
    case mb100 = 100
    case mb200 = 200
    case mb300 = 300
    case mb500 = 500

    var id: Int { rawValue }
    var bytes: Int64 { Int64(rawValue) * 1_000_000 }
    var displayName: String { "\(rawValue) MB" }
}

/// Concrete encoder settings worked out from a video and a size target.
///
/// Decided from the target, not from a preset: Apple's export presets pick
/// their own bitrate and ignore any size budget, which is why large clips were
/// still landing at 700 MB.
struct CompressionPlan: Sendable, Equatable {
    let width: Int
    let height: Int
    let frameRate: Int
    let videoBitrate: Int
    let audioBitrate: Int

    var estimatedBytes: Int64 {
        Int64(Double(videoBitrate + audioBitrate) / 8 * durationSeconds)
    }
    let durationSeconds: Double

    // MARK: Tunables

    /// Long-edge caps, biggest first. 4K is never kept — capping at 1080p was
    /// chosen deliberately for the space saving.
    static let resolutionLadder = [1920, 1280, 960, 640]

    /// Bits per pixel per frame that still looks acceptable in HEVC. Below
    /// this, spending the budget on a smaller frame beats smearing it over a
    /// big one. one constant from typical footage — raise it toward
    /// 0.08 for better quality at bigger sizes, lower for more savings.
    static let bitsPerPixelPerFrame = 0.05

    /// Never go below this, however small the target; under it HEVC falls apart.
    static let minimumVideoBitrate = 250_000

    /// Quality ceiling in bits per pixel per frame. A short clip with a
    /// generous target would otherwise be handed an absurd bitrate — a 1 second
    /// clip aimed at 200 MB works out to 1.6 Gbps, which the hardware encoder
    /// simply rejects. Spending more than this buys nothing visible anyway.
    static let maxBitsPerPixelPerFrame = 0.25

    /// Absolute ceiling, whatever the resolution.
    static let maximumVideoBitrate = 120_000_000

    static let audioBitrate = 96_000

    /// Largest share of the source's bitrate a plan may spend.
    static let maxShareOfSource = 0.6

    /// Above this frame rate a clip is slow motion, and halving it would
    /// destroy the effect rather than save space.
    static let slowMotionThreshold = 100.0

    static func plan(for metadata: VideoMetadata, target: TargetSize) -> CompressionPlan {
        plan(for: metadata, targetBytes: target.bytes)
    }

    static func plan(for metadata: VideoMetadata, targetBytes: Int64) -> CompressionPlan {
        let duration = max(metadata.duration, 0.1)

        // Frame rate: halve 60fps-class footage, leave slow motion alone.
        let sourceRate = metadata.frameRate > 0 ? metadata.frameRate : 30
        let frameRate = (sourceRate >= 50 && sourceRate < slowMotionThreshold)
            ? 30 : Int(sourceRate.rounded())

        // Budget left for video once audio is paid for.
        let budgetBits = Double(targetBytes) * 8
        let audioBits = Double(audioBitrate) * duration
        var videoBudget = max(budgetBits - audioBits, 0) / duration

        // The target is a ceiling, never a goal (QA B1): a clip already under
        // it would otherwise be handed MORE bits than it has and come out
        // bigger. Spend at most this share of what the source uses now.
        let sourceBitrate = metadata.bitrate > 0
            ? metadata.bitrate : Double(metadata.fileSize) * 8 / duration
        if sourceBitrate > 0 {
            videoBudget = min(videoBudget, max(sourceBitrate * maxShareOfSource - Double(audioBitrate), 0))
        }

        // Largest ladder step the budget can carry at acceptable quality,
        // never upscaling past the source.
        let sourceLongEdge = max(metadata.width, metadata.height)
        var chosen = (width: 0, height: 0)
        for cap in resolutionLadder {
            let (w, h) = fit(width: metadata.width, height: metadata.height,
                             longEdgeCap: min(cap, max(sourceLongEdge, 2)))
            chosen = (w, h)
            let needed = Double(w * h * frameRate) * bitsPerPixelPerFrame
            if needed <= videoBudget { break }
        }

        // Clamp into the range the encoder can actually honour.
        let ceiling = min(Double(chosen.width * chosen.height * frameRate) * maxBitsPerPixelPerFrame,
                          Double(maximumVideoBitrate))
        let bitrate = max(min(Int(videoBudget.rounded()), Int(ceiling)), minimumVideoBitrate)

        return CompressionPlan(width: chosen.width,
                               height: chosen.height,
                               frameRate: max(frameRate, 1),
                               videoBitrate: bitrate,
                               audioBitrate: audioBitrate,
                               durationSeconds: duration)
    }

    /// Scale to fit the cap without upscaling, keeping aspect ratio, with even
    /// dimensions (HEVC requires them).
    static func fit(width: Int, height: Int, longEdgeCap: Int) -> (Int, Int) {
        guard width > 0, height > 0 else { return (longEdgeCap, longEdgeCap) }
        let longEdge = max(width, height)
        let scale = min(1.0, Double(longEdgeCap) / Double(longEdge))
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}
