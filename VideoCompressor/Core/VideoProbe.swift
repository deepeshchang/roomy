import AVFoundation
import Foundation

enum VideoProbeError: Error {
    case noVideoTrack
    case unreadable
}

/// @MainActor for the same reason as VideoCompressorEngine — AVAsset
/// is non-Sendable, so probing has to share an isolation domain with whoever
/// holds the asset. The actual track loading is async inside AVFoundation.
@MainActor
enum VideoProbe {
    static func probe(url: URL) async throws -> VideoMetadata {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return try await probe(asset: AVURLAsset(url: url),
                               filename: url.lastPathComponent,
                               fileSize: (attributes?[.size] as? Int64) ?? 0)
    }

    /// Probe any AVAsset. Library assets have no stat-able path, so their size
    /// is supplied by the caller from PHAssetResource.
    static func probe(asset: AVAsset,
                      filename: String,
                      fileSize: Int64) async throws -> VideoMetadata {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProbeError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let (naturalSize, frameRate, dataRate, formats) = try await track.load(
            .naturalSize, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)

        // naturalSize ignores the display transform; a portrait clip is stored
        // landscape with a 90° transform. Apply it so the reported resolution
        // matches what the user sees.
        let transform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)

        return VideoMetadata(
            filename: filename,
            fileSize: fileSize,
            duration: CMTimeGetSeconds(duration),
            width: Int(abs(displaySize.width).rounded()),
            height: Int(abs(displaySize.height).rounded()),
            frameRate: Double(frameRate),
            codec: codecName(from: formats.first),
            bitrate: Double(dataRate)
        )
    }

    private static func codecName(from format: CMFormatDescription?) -> String {
        guard let format else { return "unknown" }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        // FourCharCode -> the four ASCII bytes, e.g. 'avc1', 'hvc1'.
        let bytes = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >> 8) & 0xFF),
            UInt8(subtype & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}
