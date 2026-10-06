import Foundation

/// Named video quality levels. A preset is a data *rate*, so a long clip gets
/// proportionally more bytes than a short one — unlike a fixed target size,
/// which squeezes a 10-minute clip and a 10-second clip into the same file.
enum VideoPreset: String, CaseIterable, Identifiable, Sendable {
    case high, balanced, maximum
    /// "Advanced": the old fixed per-video `TargetSize`.
    case custom

    var id: String { rawValue }

    /// Total budget per minute of footage. three constants chosen so a
    /// 10-minute 1080p clip lands near 450 / 200 / 90 MB; tune here.
    var bytesPerMinute: Int64? {
        switch self {
        case .high: 45_000_000
        case .balanced: 20_000_000
        case .maximum: 9_000_000
        case .custom: nil
        }
    }

    var title: String {
        switch self {
        case .high: "High quality"
        case .balanced: "Balanced"
        case .maximum: "Maximum space"
        case .custom: "Fixed size per video"
        }
    }

    var summary: String {
        switch self {
        case .high: "Looks the same as the original on a phone or TV. Saves the least."
        case .balanced: "Looks the same on a phone; slightly softer on a big screen."
        case .maximum: "Fine for keepsakes and sharing. Fast motion looks softer."
        case .custom: "Every video is squeezed to the size you pick, however long it is."
        }
    }

    /// The clip the settings screen quotes: 10 minutes of 1080p at 30 fps.
    static let exampleClip = VideoMetadata(filename: "example.mov", fileSize: 0, duration: 600,
                                           width: 1920, height: 1080, frameRate: 30,
                                           codec: "avc1", bitrate: 0)

    /// What `exampleClip` comes out at — from the real plan, not a typed number.
    var tenMinuteExampleBytes: Int64 {
        CompressionSettings(videoPreset: self).videoPlan(for: Self.exampleClip).estimatedBytes
    }
}

enum PhotoQuality: String, CaseIterable, Identifiable, Sendable {
    case high, balanced
    var id: String { rawValue }
    var value: Double { self == .high ? 0.9 : PhotoPlan.defaultQuality }
    var title: String { self == .high ? "High" : "Balanced" }
}

/// Everything the user can choose about compression, in one value.
struct CompressionSettings: Equatable, Sendable {
    var videoPreset: VideoPreset = .balanced
    var target: TargetSize = .mb200
    var photoQuality: PhotoQuality = .balanced
    var downscaleLargePhotos = true

    func videoPlan(for metadata: VideoMetadata) -> CompressionPlan {
        guard let perMinute = videoPreset.bytesPerMinute else {
            return CompressionPlan.plan(for: metadata, target: target)
        }
        let minutes = max(metadata.duration, 0.1) / 60
        return CompressionPlan.plan(for: metadata, targetBytes: Int64(Double(perMinute) * minutes))
    }

    func photoPlan(for photo: LibraryPhoto) -> PhotoPlan {
        PhotoPlan.plan(for: photo,
                       longEdgeCap: downscaleLargePhotos ? PhotoPlan.defaultLongEdgeCap : nil,
                       quality: photoQuality.value)
    }
}
