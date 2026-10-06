import Foundation

/// A probed description of one video file. Pure data — no I/O, no AVFoundation.
struct VideoMetadata: Sendable, Equatable, Codable {
    let filename: String
    let fileSize: Int64
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Double
    let codec: String
    let bitrate: Double

    var isHEVC: Bool {
        ["hvc1", "hev1", "hevc"].contains(codec.lowercased())
    }

    var isH264: Bool {
        ["h264", "avc1"].contains(codec.lowercased())
    }

    var resolutionLabel: String { "\(width)×\(height)" }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDuration: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
