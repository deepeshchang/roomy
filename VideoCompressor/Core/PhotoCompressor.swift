import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoCompressionError: Error, LocalizedError {
    case unreadable
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:   "This photo can't be read."
        case .encodeFailed: "This photo couldn't be compressed."
        }
    }
}

/// Re-encodes a photo to HEIC, optionally downscaling, preserving EXIF.
struct PhotoCompressorEngine: Sendable {

    static var workingDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compressed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func compress(data: Data, plan: PhotoPlan, basename: String) throws -> URL {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoCompressionError.unreadable
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as NSDictionary?) as? [CFString: Any] ?? [:]

        let image: CGImage
        if let cap = plan.maxLongEdge {
            // Thumbnail generation does the scaling, and applying the EXIF
            // transform here bakes orientation into the pixels.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: cap,
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary) else {
                throw PhotoCompressionError.encodeFailed
            }
            image = scaled
            // Orientation is now in the pixels; leaving the tag would rotate
            // the image a second time when it is displayed.
            properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        } else {
            guard let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PhotoCompressionError.encodeFailed
            }
            image = full
        }

        properties[kCGImageDestinationLossyCompressionQuality] = plan.quality

        let output = Self.workingDirectory
            .appendingPathComponent("\(basename)-heic-\(UUID().uuidString).heic")

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw PhotoCompressionError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw PhotoCompressionError.encodeFailed
        }
        return output
    }
}
