import Foundation
import UniformTypeIdentifiers

/// One photo in the library, described without decoding it.
struct LibraryPhoto: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let filename: String
    let fileSize: Int64
    let width: Int
    let height: Int
    let creationDate: Date?
    let uti: String?
    let isLivePhoto: Bool

    var isRAW: Bool {
        guard let uti, let type = UTType(uti) else { return false }
        return type.conforms(to: .rawImage) || uti.lowercased().contains("dng")
    }

    var isHEIC: Bool {
        guard let uti, let type = UTType(uti) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Nothing meaningful left to gain.
    ///
    /// Deliberately NOT "is this HEIC" — iPhone photos are all HEIC, so that
    /// test hid the entire library. What matters is whether a re-encode would
    /// actually save anything worth the quality cost.
    var looksAlreadyCompressed: Bool {
        if fileSize < PhotoPlan.minimumWorthwhileSize { return true }
        let plan = PhotoPlan.plan(for: self)
        guard fileSize > 0 else { return true }
        let fraction = Double(fileSize - plan.estimatedBytes) / Double(fileSize)
        return fraction < PhotoPlan.minimumSavingFraction
    }

    static func candidates(_ photos: [LibraryPhoto], handled: Set<String>) -> [LibraryPhoto] {
        photos.filter { !handled.contains($0.id) && !$0.looksAlreadyCompressed }
    }
}

/// How a photo will be re-encoded.
struct PhotoPlan: Sendable, Equatable {
    /// nil keeps the original pixel dimensions.
    let maxLongEdge: Int?
    let quality: Double
    let estimatedBytes: Int64

    /// iPhone's own full-resolution long edge. Anything bigger is a scan, an
    /// import or a 50MP camera file, and comes down to this.
    static let defaultLongEdgeCap = 4032

    /// HEIC at this quality is visually indistinguishable from the JPEG it
    /// replaces at normal viewing sizes.
    /// one constant. Lower it for more savings if you ever decide the
    /// quality headroom is wasted.
    static let defaultQuality = 0.8

    /// Expected HEIC size relative to the source format, before any downscale.
    /// measured rules of thumb, not per-image analysis — the real
    /// size is only known after encoding, and encoding to find out would double
    /// the work for every photo in a 500-photo batch.
    static func formatRatio(uti: String?) -> Double {
        guard let uti, let type = UTType(uti) else { return 0.45 }
        if type.conforms(to: .png) { return 0.12 }   // screenshots collapse
        if type.conforms(to: .rawImage) || uti.lowercased().contains("dng") { return 0.08 }
        // HEIC -> HEIC still gains: the camera encodes at a higher quality than
        // 0.8, so a re-encode typically lands 30-50% smaller.
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return 0.6 }
        return 0.40                                   // JPEG and everything else
    }

    /// Under this there is nothing worth reclaiming, whatever the ratio says.
    static let minimumWorthwhileSize: Int64 = 300_000

    /// Re-encoding costs a little quality, so require a real gain to bother.
    static let minimumSavingFraction = 0.15

    static func plan(for photo: LibraryPhoto,
                     longEdgeCap: Int? = defaultLongEdgeCap,
                     quality: Double = defaultQuality) -> PhotoPlan {
        let sourceLongEdge = max(photo.width, photo.height)
        let cap = longEdgeCap.flatMap { $0 < sourceLongEdge ? $0 : nil }

        // Downscaling cuts bytes roughly with the pixel count, so with the
        // square of the linear scale.
        var pixelFactor = 1.0
        if let cap, sourceLongEdge > 0 {
            let scale = Double(cap) / Double(sourceLongEdge)
            pixelFactor = scale * scale
        }

        // one measured-ish factor for quality above the default; HEIC
        // at 0.9 runs roughly half again bigger than at 0.8.
        let qualityFactor = quality > defaultQuality ? 1.5 : 1.0
        let estimated = Double(photo.fileSize) * formatRatio(uti: photo.uti) * pixelFactor * qualityFactor
        return PhotoPlan(maxLongEdge: cap,
                         quality: quality,
                         estimatedBytes: Int64(max(estimated, 0)))
    }
}
