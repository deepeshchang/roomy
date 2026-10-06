import AVFoundation
import CoreLocation
import Foundation
import Photos

/// One video in the user's library, described without loading its bytes.
struct LibraryVideo: Identifiable, Sendable, Equatable {
    let id: String              // PHAsset.localIdentifier
    let filename: String
    let fileSize: Int64
    let duration: Double
    let creationDate: Date?
    let width: Int
    let height: Int

    /// Bits per pixel per second — how hard the encoder is already working.
    var bitsPerPixelSecond: Double {
        let pixels = Double(width * height)
        guard duration > 0, pixels > 0 else { return .infinity }
        return Double(fileSize) * 8 / duration / pixels
    }

    /// Below this, re-encoding to HEVC recovers too little to be worth it.
    ///
    /// one threshold from typical iPhone footage — H.264 lands around
    /// 5-12 bits/pixel/s, HEVC (including this app's own output) around 2-4.
    /// A screen recording or a very static clip can dip under it while still
    /// being H.264; that's acceptable because it would compress poorly too.
    /// Tune this number rather than adding codec probing, which would mean
    /// loading every video in the library.
    static let alreadyCompressedThreshold = 4.0

    var looksAlreadyCompressed: Bool {
        bitsPerPixelSecond < Self.alreadyCompressedThreshold
    }

    /// Candidates worth compressing: not handled by this app before, and not
    /// already encoded efficiently.
    static func candidates(_ videos: [LibraryVideo], handled: Set<String>) -> [LibraryVideo] {
        videos.filter { !handled.contains($0.id) && !$0.looksAlreadyCompressed }
    }

    /// Everything the list needs, known without loading a single video frame.
    var placeholderMetadata: VideoMetadata {
        VideoMetadata(filename: filename, fileSize: fileSize, duration: duration,
                      width: width, height: height, frameRate: 0,
                      codec: "unknown",
                      bitrate: duration > 0 ? Double(fileSize) * 8 / duration : 0)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDuration: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Carries a non-Sendable AVAsset across an isolation boundary. Safe because
/// exactly one reference is handed over and the producer keeps none.
struct AVAssetBox: @unchecked Sendable {
    let asset: AVAsset
}

/// Same idea for metadata items, which are also non-Sendable.
struct MetadataBox: @unchecked Sendable {
    let items: [AVMetadataItem]
    init(_ items: [AVMetadataItem]) { self.items = items }
}

enum PhotoLibraryError: Error, LocalizedError {
    case permissionDenied
    case assetMissing
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Roomy needs permission to see your videos. You can grant it in Settings."
        case .assetMissing:
            "That video is no longer in your library."
        case .exportFailed(let why):
            "Couldn't read that video: \(why)"
        }
    }
}

/// Reads the photo library so videos can be listed largest-first.
///
/// SAFETY: the only mutating call in this type is `deleteOriginal(id:)`, which
/// the user invokes per item after their compressed copy is already saved.
/// iOS shows its own system confirmation for every deletion and the asset goes
/// to Recently Deleted for 30 days. Nothing here edits an existing asset.
enum PhotoLibrary {

    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Pure sort, split out so it is testable without a real library.
    static func sortedLargestFirst(_ videos: [LibraryVideo]) -> [LibraryVideo] {
        videos.sorted {
            $0.fileSize != $1.fileSize ? $0.fileSize > $1.fileSize : $0.filename < $1.filename
        }
    }

    /// Serialises cache saves: videos and photos scan concurrently and share one file.
    private static let cacheLock = NSLock()

    /// At most ~10 progress calls per second, plus the final one.
    private final class Throttle: @unchecked Sendable {
        private var last = Date.distantPast
        func fire(final: Bool) -> Bool {
            let now = Date()
            guard final || now.timeIntervalSince(last) >= 0.1 else { return false }
            last = now
            return true
        }
    }

    /// Walks every asset of one media type off the main thread. Cached sizes
    /// skip the resource reads; only new or edited assets pay for them.
    /// `kind` namespaces cache keys so one scan never prunes the other's entries.
    private nonisolated static func scan<T: Sendable>(
        mediaType: PHAssetMediaType,
        kind: String,
        onProgress: (@Sendable (Int, Int) -> Void)?,
        read: (PHAsset) -> (size: Int64, filename: String, uti: String?, measured: Bool),
        build: (PHAsset, SizeCache.Entry) -> T
    ) -> [T] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        let total = result.count

        var cache = SizeCache.load(from: SizeCache.defaultURL)
        var seen = Set<String>()
        var items: [T] = []
        items.reserveCapacity(total)
        let throttle = Throttle()

        if total == 0 { onProgress?(0, 0) }   // always signal completion
        for index in 0..<total {
            let asset = result.object(at: index)
            let key = kind + asset.localIdentifier
            seen.insert(key)
            let (entry, _) = cache.resolve(key, modified: asset.modificationDate) { read(asset) }
            items.append(build(asset, entry))
            if let onProgress, throttle.fire(final: index == total - 1) {
                onProgress(index + 1, total)
            }
        }

        // Merge into whatever is on disk now (the other scan may have saved),
        // dropping only this kind's vanished assets.
        cacheLock.lock(); defer { cacheLock.unlock() }
        var merged = SizeCache.load(from: SizeCache.defaultURL)
        merged.merge(cache.entries(withPrefix: kind))
        if SizeCache.shouldPrune(
            authorizationLimited: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
            total: total) {
            merged.prune(keeping: seen.union(merged.ids.filter { !$0.hasPrefix(kind) }))
        }
        try? merged.save(to: SizeCache.defaultURL)
        return items
    }

    /// Every video in the library, biggest first.
    nonisolated static func fetchVideosLargestFirst(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [LibraryVideo] {
        guard await requestAccess() else { return [] }

        let videos = scan(mediaType: .video, kind: "v:", onProgress: onProgress, read: { asset in
            let resources = PHAssetResource.assetResources(for: asset)
            let resource = resources.first { $0.type == .video } ?? resources.first

            // `fileSize` is an undocumented KVC key on PHAssetResource.
            // It is the only way to get a byte count without downloading the
            // asset. It is guarded by responds(to:) because a plain valueForKey
            // on a resource that does not implement it raises
            // NSUnknownKeyException — an ObjC exception Swift cannot catch, so
            // it would take the whole app down. Falls back to a nominal
            // bitrate, which still ranks items correctly.
            let measured = Self.resourceFileSize(resource)
            let size = measured ?? Int64(asset.duration * 2_000_000)
            return (size, resource?.originalFilename ?? "Video", nil, measured != nil)
        }, build: { asset, entry in
            LibraryVideo(
                id: asset.localIdentifier,
                filename: entry.filename,
                fileSize: entry.size,
                duration: asset.duration,
                creationDate: asset.creationDate,
                width: asset.pixelWidth,
                height: asset.pixelHeight
            )
        })

        return sortedLargestFirst(videos)
    }

    /// Byte count of a resource without downloading it, or nil when PhotoKit
    /// does not expose one for this resource type.
    private static func resourceFileSize(_ resource: PHAssetResource?) -> Int64? {
        guard let resource, resource.responds(to: Selector(("fileSize"))) else { return nil }
        return fileSize(fromKVC: resource.value(forKey: "fileSize"))
    }

    /// A zero or negative size is garbage: treated as unmeasured.
    nonisolated static func fileSize(fromKVC raw: Any?) -> Int64? {
        let value: Int64
        switch raw {
        case let v as Int64:  value = v
        case let v as Int:    value = Int64(v)
        case let v as NSNumber: value = v.int64Value
        default: return nil
        }
        return value > 0 ? value : nil
    }

    /// Everything about a library original that decides where its copy lands
    /// in the timeline and which albums it appears in.
    struct OriginalInfo: Sendable {
        let creationDate: Date?
        let location: CLLocation?
        let isFavorite: Bool
        let isHidden: Bool
        let albumIDs: [String]
    }

    static func originalInfo(id: String) -> OriginalInfo? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                              options: nil).firstObject else { return nil }
        var albumIDs: [String] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { collection, _, _ in
                // Only user albums accept new items; smart albums fill themselves.
                if collection.canPerform(.addContent) { albumIDs.append(collection.localIdentifier) }
            }
        return OriginalInfo(creationDate: asset.creationDate,
                            location: asset.location,
                            isFavorite: asset.isFavorite,
                            isHidden: asset.isHidden,
                            albumIDs: albumIDs)
    }

    /// QuickTime metadata for the compressed file: the source's own items, with
    /// creation date and GPS guaranteed present.
    ///
    /// The source's embedded `creationdate` is kept verbatim when it exists —
    /// it carries the original timezone offset, which a `Date` cannot. Only
    /// when the file has none is one synthesised from the library date.
    static func quickTimeMetadata(source: [AVMetadataItem],
                                  creationDate: Date?,
                                  location: CLLocation?) -> [AVMetadataItem] {
        var items = source
        let has = { (id: AVMetadataIdentifier) in items.contains { $0.identifier == id } }

        if !has(.quickTimeMetadataCreationDate), let creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = ISO8601DateFormatter.string(from: creationDate,
                                                     timeZone: .current,
                                                     formatOptions: [.withInternetDateTime]) as NSString
            items.append(item)
        }
        if !has(.quickTimeMetadataLocationISO6709), let location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = iso6709(location) as NSString
            items.append(item)
        }
        return items
    }

    /// e.g. "+12.9716+077.5946+920.000/"
    static func iso6709(_ location: CLLocation) -> String {
        String(format: "%+08.4f%+09.4f%+08.3f/",
               location.coordinate.latitude,
               location.coordinate.longitude,
               location.altitude)
    }

    /// Which of these IDs still exist in the library this app can see.
    static func existingIDs(_ ids: [String]) -> Set<String> {
        var found = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        return found
    }

    /// Delete several originals in ONE request, so iOS shows one confirmation
    /// for the whole batch instead of fifty. Returns false if declined.
    static func deleteOriginals(ids: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            return false
        }
    }

    /// Delete one original from the library. iOS presents its own confirmation
    /// sheet; the asset lands in Recently Deleted and is recoverable for 30 days.
    /// Returns false if the user declines the system prompt.
    static func deleteOriginal(id: String) async throws -> Bool {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                              options: nil).firstObject else {
            throw PhotoLibraryError.assetMissing
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            return true
        } catch {
            // The user tapping "Don't Allow" on the system sheet arrives here.
            return false
        }
    }

    /// Every photo in the library, biggest first.
    nonisolated static func fetchPhotosLargestFirst(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [LibraryPhoto] {
        guard await requestAccess() else { return [] }

        let photos = scan(mediaType: .image, kind: "p:", onProgress: onProgress, read: { asset in
            let resources = PHAssetResource.assetResources(for: asset)
            // A Live Photo has two resources; the still is the one to measure.
            let resource = resources.first { $0.type == .photo }
                ?? resources.first { $0.type == .fullSizePhoto }
                ?? resources.first
            // Falling through to a guard here silently dropped photos whose
            // size PhotoKit would not report. Estimate instead, so they stay
            // visible and merely sort approximately.
            let measured = Self.resourceFileSize(resource)
            let size = measured ?? Int64(Double(asset.pixelWidth * asset.pixelHeight) * 0.2)
            return (size, resource?.originalFilename ?? "Photo",
                    resource?.uniformTypeIdentifier, measured != nil)
        }, build: { asset, entry in
            LibraryPhoto(
                id: asset.localIdentifier,
                filename: entry.filename,
                fileSize: entry.size,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                creationDate: asset.creationDate,
                uti: entry.uti,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
        })

        return photos.sorted {
            $0.fileSize != $1.fileSize ? $0.fileSize > $1.fileSize : $0.filename < $1.filename
        }
    }

    /// The original bytes of a photo, downloading from iCloud if needed.
    nonisolated static func imageData(id: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                              options: nil).firstObject else {
            throw PhotoLibraryError.assetMissing
        }
        let options = PHImageRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none

        final class Once: @unchecked Sendable {
            private let lock = NSLock(); private var claimed = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }
                if claimed { return false }; claimed = true; return true }
        }
        let once = Once()

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options) { data, _, _, info in
                guard once.claim() else { return }
                if let data {
                    continuation.resume(returning: data)
                } else {
                    let reason = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                        ?? "the photo could not be loaded"
                    continuation.resume(throwing: PhotoLibraryError.exportFailed(reason))
                }
            }
        }
    }

    /// Write a Live Photo's video half to a file so it can be re-paired.
    ///
    /// passed through untouched rather than re-encoded. It is a 1-3
    /// second clip, the still is where the bytes are, and a failed re-pair
    /// silently turns a Live Photo into a plain one.
    nonisolated static func pairedVideoFile(id: String) async throws -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                              options: nil).firstObject else { return nil }
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo })
        else { return nil }

        let destination = importedDirectory
            .appendingPathComponent("live-\(UUID().uuidString).mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination,
                                                       options: options) { error in
                if let error {
                    c.resume(throwing: PhotoLibraryError.exportFailed(error.localizedDescription))
                } else { c.resume() }
            }
        }
        return destination
    }

    /// Where library copies land before compression.
    static var importedDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An AVAsset reading straight from the library — no sandbox duplicate.
    ///
    /// This is what makes large files work: copying a 1.8 GB original into the
    /// app container before compressing needs double the free space and several
    /// minutes of I/O, and the Caches directory can be purged mid-write.
    /// AVAssetExportSession reads the library asset in place instead.
    /// Resolve an AVAsset for a library video.
    ///
    /// - Parameter allowNetwork: false keeps this local-only and fast — it
    ///   returns nil-ish immediately when the original lives in iCloud instead
    ///   of silently downloading gigabytes. Listing uses false; compressing
    ///   uses true and reports download progress.
    /// NOT @MainActor. PhotoKit invokes its result handler on its own
    /// `com.apple.photos.requestAVAsset` queue. Marking this @MainActor made
    /// the handler closure inherit MainActor isolation, so Swift's runtime
    /// isolation check tripped `dispatch_assert_queue_fail` and killed the app
    /// the moment a video was selected. The asset instead rides home in a
    /// Sendable box which the (MainActor) caller unwraps.
    nonisolated static func avAsset(
        id: String,
        allowNetwork: Bool,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AVAssetBox {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                              options: nil).firstObject else {
            throw PhotoLibraryError.assetMissing
        }
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowNetwork
        if let onDownloadProgress {
            // Also called off the main queue — kept nonisolated for the same
            // reason as the result handler.
            options.progressHandler = { progress, _, _, _ in
                onDownloadProgress(progress)
            }
        }

        // PhotoKit may invoke this result handler more than once (a degraded
        // result followed by the final one, or a cancellation racing a
        // delivery). Resuming a continuation twice is an immediate fatal
        // crash, so the first delivery wins and the rest are dropped.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if claimed { return false }
                claimed = true
                return true
            }
        }
        let once = Once()

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset,
                                                    options: options) { avAsset, _, info in
                guard once.claim() else { return }
                if let avAsset {
                    continuation.resume(returning: AVAssetBox(asset: avAsset))
                } else {
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    let reason = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                        ?? (inCloud
                            ? "this video is stored in iCloud, not on the device"
                            : "the video could not be loaded from your library")
                    continuation.resume(throwing: PhotoLibraryError.exportFailed(reason))
                }
            }
        }
    }

    /// Copy the original bytes of one library video into our sandbox.
    /// Reads only — the library asset is untouched.
    static func exportOriginal(id: String) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],
                                              options: nil).firstObject else {
            throw PhotoLibraryError.assetMissing
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first else {
            throw PhotoLibraryError.assetMissing
        }

        let ext = (resource.originalFilename as NSString).pathExtension
        let destination = importedDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // fetch from iCloud if needed

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource,
                                                       toFile: destination,
                                                       options: options) { error in
                if let error {
                    c.resume(throwing: PhotoLibraryError.exportFailed(error.localizedDescription))
                } else {
                    c.resume()
                }
            }
        }
        return destination
    }
}
