import AVFoundation
import Photos
import UIKit

/// Carries a non-Sendable UIImage back from PhotoKit's queue to the caller.
/// Same deal as AVAssetBox in PhotoLibrary: one reference is handed over and
/// the producer keeps none.
struct UIImageBox: @unchecked Sendable {
    let image: UIImage?
}

/// Thumbnails for the library browser and the batch queue.
///
/// @MainActor for the same reason as VideoProbe: UIImage is not Sendable, so
/// the images have to live in the same isolation domain as the views holding
/// them. The PhotoKit call itself is deliberately NOT in that domain — see
/// `requestImage` below.
@MainActor
enum Thumbnails {

    /// One shared caching manager. PHCachingImageManager is documented as safe
    /// to call from any queue, and the whole point is that the cache outlives
    /// any single view, so it cannot be MainActor-isolated state.
    nonisolated(unsafe) private static let manager = PHCachingImageManager()

    /// Square thumbnail for a library asset. nil when the asset is gone, or
    /// when its only copy lives in iCloud.
    static func image(for assetID: String, size: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID],
                                              options: nil).firstObject else { return nil }
        return await requestImage(asset: asset, target: targetSize(size)).image
    }

    /// First-frame thumbnail for an item that came from a file on disk.
    static func image(for fileURL: URL, size: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize(size)
        // Generous tolerance: any nearby keyframe is a fine thumbnail and
        // exact seeking would decode frames for no visible benefit.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Tell the cache which assets are about to be shown / are gone.
    /// Unknown identifiers are silently ignored, which is what a grid scrolling
    /// past a deleted asset needs.
    static func startCaching(assetIDs: [String], size: CGFloat) {
        let assets = self.assets(assetIDs)
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: targetSize(size),
                                   contentMode: .aspectFill, options: requestOptions)
    }

    static func stopCaching(assetIDs: [String], size: CGFloat) {
        let assets = self.assets(assetIDs)
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: targetSize(size),
                                  contentMode: .aspectFill, options: requestOptions)
    }

    // MARK: - Internals

    private static func assets(_ ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        var found: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { asset, _, _ in found.append(asset) }
        return found
    }

    /// Points in, pixels out — a thumbnail asked for in points on a 3x screen
    /// and cached in points would be visibly soft.
    private static func targetSize(_ side: CGFloat) -> CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: side * scale, height: side * scale)
    }

    /// The same options object for fetching and for caching, so a cached image
    /// actually satisfies the later request.
    ///
    /// isNetworkAccessAllowed = false is the non-negotiable one: a thumbnail
    /// must never trigger an iCloud download. That silent multi-second stall
    /// made the app look frozen once already (see BatchStore's note on the
    /// same flag). A grey placeholder for an iCloud-only asset is correct.
    ///
    /// .highQualityFormat rather than .opportunistic. Opportunistic
    /// delivers a degraded image first and a good one later, but this API
    /// returns exactly once, so the Once guard below would pin the blurry one
    /// forever. Local-only thumbnails come from PhotoKit's own prebuilt cache
    /// and are fast. Switch to .opportunistic only alongside an API that can
    /// call back twice.
    nonisolated private static var requestOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        return options
    }

    /// NOT @MainActor. PhotoKit invokes the result handler on its own queue;
    /// marking the enclosing function @MainActor makes the closure inherit
    /// MainActor isolation and the runtime isolation check then trips
    /// `dispatch_assert_queue_fail` and kills the app — exactly the crash
    /// PhotoLibrary.avAsset documents. The image rides home in a Sendable box
    /// that the MainActor caller unwraps.
    nonisolated private static func requestImage(asset: PHAsset,
                                                 target: CGSize) async -> UIImageBox {
        // The handler can fire more than once (a degraded result followed by
        // the final one, or a cancellation racing a delivery). A second
        // continuation.resume is a fatal crash, so first delivery wins.
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

        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill,
                                 options: requestOptions) { image, _ in
                guard once.claim() else { return }
                continuation.resume(returning: UIImageBox(image: image))
            }
        }
    }
}
