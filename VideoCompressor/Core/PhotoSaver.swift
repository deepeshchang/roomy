import CoreLocation
import Foundation
import Photos

enum PhotoSaverError: Error, LocalizedError {
    case permissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Roomy needs permission to add videos to Photos. You can grant it in Settings."
        case .saveFailed(let why):
            "Couldn't save to Photos: \(why)"
        }
    }
}

/// Writes finished videos into Photos as NEW assets that sit exactly where the
/// original sat: same date, place, favourite and hidden state, same albums.
enum PhotoSaver {
    /// - Returns: the new asset's localIdentifier.
    /// The file is MOVED into Photos, not copied — keeping a second copy in the
    /// app's cache would eat the very space a 50-video batch is meant to free.
    static func save(_ url: URL, like original: PhotoLibrary.OriginalInfo?) async throws -> String? {
        try await create(like: original) { request in
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }

    /// Save a compressed photo. Supplying `pairedVideo` recreates a Live Photo.
    static func savePhoto(_ url: URL,
                          pairedVideo: URL?,
                          like original: PhotoLibrary.OriginalInfo?) async throws -> String? {
        try await create(like: original) { request in
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .photo, fileURL: url, options: options)
            if let pairedVideo {
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = true
                request.addResource(with: .pairedVideo, fileURL: pairedVideo,
                                    options: videoOptions)
            }
        }
    }

    private static func create(
        like original: PhotoLibrary.OriginalInfo?,
        addResources: @escaping @Sendable (PHAssetCreationRequest) -> Void
    ) async throws -> String? {
        guard await PhotoLibrary.requestAccess() else {
            throw PhotoSaverError.permissionDenied
        }
        var newID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                addResources(request)

                if let original {
                    request.creationDate = original.creationDate
                    request.location = original.location
                    request.isFavorite = original.isFavorite
                    request.isHidden = original.isHidden

                    if let placeholder = request.placeholderForCreatedAsset {
                        let albums = PHAssetCollection.fetchAssetCollections(
                            withLocalIdentifiers: original.albumIDs, options: nil)
                        albums.enumerateObjects { album, _, _ in
                            PHAssetCollectionChangeRequest(for: album)?
                                .addAssets([placeholder] as NSArray)
                        }
                    }
                }
                newID = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PhotoSaverError.saveFailed(error.localizedDescription)
        }
        return newID
    }
}
