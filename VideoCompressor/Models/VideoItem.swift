import AVFoundation
import Foundation
import Observation

enum ItemState: Equatable, Sendable {
    case pending
    case probing
    case ready
    case downloading(Double)
    case compressing
    case finished
    /// Nothing worth saving: skipped before work, or its output wasn't
    /// smaller. Neutral, not a failure.
    case alreadySmall
    case failed(String)
}

enum MediaKind: String, Sendable, Codable { case video, photo }

@Observable
@MainActor
final class VideoItem: Identifiable {
    /// Videos and photos share the whole pipeline — listing, batching,
    /// background running, saving, the ledger, deletion. Only the encode step
    /// differs, so they share one item type with a kind tag.
    let kind: MediaKind

    /// Set for photo items.
    var photo: LibraryPhoto?

    let id = UUID()

    /// Set only for items that came from a file on disk. Library items have no
    /// stat-able path — they are read in place through `sourceAsset`.
    let sourceURL: URL?

    /// PHAsset.localIdentifier of the library original, when this item came
    /// from the library browser. Needed to copy metadata and to offer deletion.
    let assetID: String?

    /// Set once the compressed copy is confirmed in Photos. Deleting the
    /// original is gated on this — never offer deletion before the replacement
    /// exists.
    var savedToPhotos = false
    var originalDeleted = false

    /// The library asset, read in place. Never a sandbox copy — duplicating a
    /// multi-gigabyte original is what broke large files.
    var sourceAsset: AVAsset?

    /// What the export session reads from, whichever way this item arrived.
    var exportAsset: AVAsset? {
        sourceAsset ?? sourceURL.map { AVURLAsset(url: $0) }
    }

    var basename: String {
        if let name = metadata?.filename { return (name as NSString).deletingPathExtension }
        return sourceURL?.deletingPathExtension().lastPathComponent ?? "video"
    }

    var metadata: VideoMetadata?
    var estimate: SavingsEstimate?
    var state: ItemState = .pending
    var outputURL: URL?
    var outputSize: Int64?
    /// localIdentifier of the compressed copy once it is in Photos.
    var savedAssetID: String?
    var progress: Double = 0

    /// Bytes actually saved. Zero until the item finishes.
    /// Recorded at compress time, because the file is later moved into Photos.
    var actualSavedBytes: Int64 {
        guard state == .finished, let outputSize, sourceBytes > 0 else { return 0 }
        return max(0, sourceBytes - outputSize)
    }

    /// True only when a compressed copy is safely in Photos and the original
    /// is still there to remove.
    var canDeleteOriginal: Bool {
        savedToPhotos && savedAssetID != nil && !originalDeleted && assetID != nil
    }

    /// Source size, whichever kind this is.
    var sourceBytes: Int64 { photo?.fileSize ?? metadata?.fileSize ?? 0 }

    var displayName: String {
        photo?.filename ?? metadata?.filename ?? sourceURL?.lastPathComponent ?? "Media"
    }

    init(sourceURL: URL?, assetID: String? = nil,
         kind: MediaKind = .video, photo: LibraryPhoto? = nil) {
        self.sourceURL = sourceURL
        self.assetID = assetID
        self.kind = kind
        self.photo = photo
    }
}
