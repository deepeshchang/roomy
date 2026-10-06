import AVFoundation
import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class BatchStore {
    var items: [VideoItem] = []
    var settings = CompressionSettings() {
        didSet {
            guard oldValue != settings else { return }
            reestimateAll()
        }
    }
    /// The Advanced fixed size. Kept as its own property for older call sites.
    var target: TargetSize {
        get { settings.target }
        set { settings.target = newValue }
    }

    /// The Library's selection. Held here so it is saved with the queue and
    /// survives the app being killed.
    var selection = LibrarySelection()

    /// Where the queue is saved; nil keeps it in memory (tests).
    let saveURL: URL?

    init(saveURL: URL? = nil) {
        self.saveURL = saveURL
    }
    var isCompressing = false

    /// Largest-first when on. a Bool, not a sort-order enum — there
    /// are only two orders and `items` already holds the picked order, so the
    /// "off" case needs no representation of its own.
    var sortedBySize = false

    private let engine = VideoCompressorEngine()
    private let photoEngine = PhotoCompressorEngine()

    /// What the list renders. Sorting is presentation only; `items` keeps the
    /// order they were picked in so toggling back is lossless.
    var displayItems: [VideoItem] {
        guard sortedBySize else { return items }
        return items.sorted { $0.sourceBytes > $1.sourceBytes }
    }

    var totalSavedBytes: Int64 {
        items.reduce(0) { $0 + $1.actualSavedBytes }
    }

    /// Set when a run begins, cleared by `clear()`. Phase can't be derived
    /// from counts alone: a cancel during the first item leaves every item
    /// ready, which looked exactly like "never started" (QA B2).
    var hasStarted = false

    /// Bumped when a batch is closed, so the Library reloads and drops items
    /// that were just compressed (QA M5).
    var libraryGeneration = 0

    var hasWork: Bool {
        items.contains { $0.state == .ready }
    }

    /// Put library items in the batch at once, with estimates from what
    /// PHAsset already knows, so the Batch screen never shows an empty or
    /// half-built queue. Probing for the real codec happens after, in `refine`.
    func enqueue(videos: [LibraryVideo], photos: [LibraryPhoto]) {
        let new = videos.map { v in
            let item = VideoItem(sourceURL: nil, assetID: v.id)
            item.metadata = v.placeholderMetadata
            return item
        } + photos.map { VideoItem(sourceURL: nil, assetID: $0.id, kind: .photo, photo: $0) }
        items.append(contentsOf: new)
        new.forEach(applyEstimate)
        save()
    }

    /// Best effort, local only: fills in the real codec and frame rate when the
    /// original is on the device. An iCloud-only original stays on the
    /// placeholder rather than triggering a silent download — that download is
    /// what made this look stuck on "Reading". Reading a library item in place:
    /// nothing is copied.
    func refine(videos: [LibraryVideo]) async {
        for video in videos {
            guard let box = try? await PhotoLibrary.avAsset(id: video.id, allowNetwork: false),
                  case let asset = box.asset,
                  let probed = try? await VideoProbe.probe(asset: asset, filename: video.filename,
                                                           fileSize: video.fileSize) else { continue }
            // Only items still waiting; one already running keeps what it has.
            for item in items where item.assetID == video.id && item.sourceAsset == nil
                && [.pending, .ready, .alreadySmall].contains(item.state) {
                item.sourceAsset = asset
                item.metadata = probed
                applyEstimate(item)
            }
        }
        save()
    }

    func add(libraryVideos: [LibraryVideo]) async {
        enqueue(videos: libraryVideos, photos: [])
        await refine(videos: libraryVideos)
    }

    func add(photos: [LibraryPhoto]) async {
        enqueue(videos: [], photos: photos)
    }

    func add(urls: [URL], assetIDs: [String] = []) async {
        let new = urls.enumerated().map { index, url in
            VideoItem(sourceURL: url,
                      assetID: index < assetIDs.count ? assetIDs[index] : nil)
        }
        items.append(contentsOf: new)

        // Probe sequentially. A batch is a handful of files and sequential
        // probing keeps the list animating in a predictable order.
        // swap to a TaskGroup if someone picks hundreds at once.
        for item in new {
            item.state = .probing
            do {
                guard let url = item.sourceURL else {
                    item.state = .failed("This video could not be read.")
                    continue
                }
                let metadata = try await VideoProbe.probe(url: url)
                item.metadata = metadata
                item.state = .ready
                applyEstimate(item)
            } catch {
                // One bad file must not take down the batch (spec R4).
                item.state = .failed(error.localizedDescription)
            }
        }
    }

    /// The one-button flow: compress every ready video in sequence, save each
    /// to Photos as soon as it finishes, and keep going in the background.
    func startBatch() {
        guard !isCompressing, hasWork else { return }
        let total = items.filter { $0.state == .ready }.count

        lastRemoved = nil
        eta = ETAEstimator()
        let startedAt = Date()
        BackgroundRunner.shared.begin(total: total)
        BackgroundRunner.shared.onExpire = { [weak self] in self?.batchTask?.cancel() }
        UIApplication.shared.isIdleTimerDisabled = true   // if left open, don't lock mid-batch

        batchTask = Task {
            var done = 0
            await compressAll(autoSave: true) { [weak self] finished, current in
                done = finished
                BackgroundRunner.shared.report(done: finished, current: current)
                guard let self, total > 0 else { return }
                let fraction = (Double(finished) + current) / Double(total)
                timeRemainingText = eta.update(fraction: fraction,
                                               elapsed: Date().timeIntervalSince(startedAt))
                    .map(ETAEstimator.text(for:))
            }
            timeRemainingText = nil
            UIApplication.shared.isIdleTimerDisabled = false
            BackgroundRunner.shared.finish(success: done == total)
            batchTask = nil
        }
    }

    private var batchTask: Task<Void, Never>?

    /// "About 4 min left", or nil while there isn't a trustworthy estimate.
    var timeRemainingText: String?
    private var eta = ETAEstimator()

    /// Stop the running batch. Finished items stay finished and saved; the
    /// one in progress is discarded (its partial file removed, the original
    /// only ever read); the rest go back to ready.
    func cancelBatch() {
        batchTask?.cancel()
    }

    /// - Parameters:
    ///   - autoSave: save each finished video to Photos straight away. Off in
    ///     tests, which have no photo library.
    ///   - onProgress: (videos finished, progress of the one in flight).
    func compressAll(autoSave: Bool = false,
                     onProgress: (@MainActor @Sendable (Int, Double) -> Void)? = nil) async {
        guard !isCompressing else { return }
        isCompressing = true
        hasStarted = true
        defer { isCompressing = false; save() }

        var finished = 0
        // Re-checked every pass, so items added mid-batch are picked up (QA M2).
        // Every path below moves the item off .ready or breaks.
        while let item = items.first(where: { $0.state == .ready }) {
            // Background time ran out: leave the rest ready for next time.
            if Task.isCancelled { break }

            item.state = .compressing
            item.progress = 0
            // Saved after every item, so a kill loses at most the one in flight.
            defer { save() }
            do {
                if item.kind == .photo {
                    try await compressPhoto(item)
                    if discardIfNotSmaller(item) { continue }
                    if autoSave { try await saveToPhotos(item) }
                    finished += 1
                    onProgress?(finished, 0)
                    continue
                }
                // Resolve the asset now, downloading from iCloud if needed —
                // with visible progress, unlike the silent stall this replaces.
                var asset = item.exportAsset
                if asset == nil, let assetID = item.assetID {
                    item.state = .downloading(0)
                    asset = try await PhotoLibrary.avAsset(id: assetID,
                                                            allowNetwork: true) { fraction in
                        Task { @MainActor in item.state = .downloading(fraction) }
                    }.asset
                    item.sourceAsset = asset
                }
                guard let asset else {
                    item.state = .failed("This video could not be read.")
                    continue
                }
                if let shortfall = Self.freeSpaceShortfall(for: item) {
                    item.state = .failed(shortfall)
                    continue
                }

                let original = item.assetID.flatMap { PhotoLibrary.originalInfo(id: $0) }
                let sourceMetadata = (try? await asset.load(.metadata)) ?? []
                let metadata = PhotoLibrary.quickTimeMetadata(source: sourceMetadata,
                                                              creationDate: original?.creationDate,
                                                              location: original?.location)

                item.state = .compressing
                let plan = settings.videoPlan(for: item.metadata ?? .init(
                    filename: item.basename, fileSize: 0, duration: 0, width: 0, height: 0,
                    frameRate: 0, codec: "", bitrate: 0))
                let captured = finished
                let output = try await engine.compress(
                    asset: AVAssetBox(asset: asset),
                    basename: item.basename,
                    plan: plan,
                    metadata: MetadataBox(metadata)
                ) { fraction in
                    Task { @MainActor in
                        item.progress = fraction
                        onProgress?(captured, fraction)
                    }
                }
                item.outputURL = output
                item.outputSize = (try? FileManager.default
                    .attributesOfItem(atPath: output.path)[.size] as? Int64) ?? nil
                item.state = .finished
                item.progress = 1.0
                if discardIfNotSmaller(item) { continue }

                if autoSave { try await saveToPhotos(item) }
                finished += 1
                onProgress?(finished, 0)
            } catch CompressionError.cancelled {
                item.state = .ready   // not a failure: pick it up next run
                item.progress = 0
                break
            } catch {
                item.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Save one finished item's compressed copy into Photos, filed under the
    /// original's date and location.
    func saveToPhotos(_ item: VideoItem) async throws {
        guard let output = item.outputURL, !item.savedToPhotos else { return }
        let original = item.assetID.flatMap { PhotoLibrary.originalInfo(id: $0) }

        if item.kind == .photo {
            let paired = (item.photo?.isLivePhoto == true && item.assetID != nil)
                ? try? await PhotoLibrary.pairedVideoFile(id: item.assetID!)
                : nil
            // The paired clip carries GPS; never leave it in Caches.
            defer { if let paired { try? FileManager.default.removeItem(at: paired) } }
            item.savedAssetID = try await PhotoSaver.savePhoto(output, pairedVideo: paired,
                                                               like: original)
            item.savedToPhotos = true
            item.outputURL = nil
            CompressionLedger().record(original: item.assetID, compressed: item.savedAssetID)
            recordReady(item)
            return
        }
        item.savedAssetID = try await PhotoSaver.save(output, like: original)
        item.savedToPhotos = true
        CompressionLedger().record(original: item.assetID, compressed: item.savedAssetID)
        recordReady(item)
        item.outputURL = nil   // moved into Photos; the cache copy is gone
    }

    /// Compressed and safely in Photos: "ready to free" until iOS confirms
    /// the original is deleted. Persisted, so it outlives this batch.
    private func recordReady(_ item: VideoItem) {
        guard let id = item.assetID else { return }
        SavingsStats.update { $0.recordCompressed(id: id, kind: item.kind, savedBytes: item.actualSavedBytes,
                                                copyID: item.savedAssetID) }
    }

    // MARK: Batch screen state (spec §11.4). Derived, never stored, so it is
    // correct on return from the background with nothing to re-sync.

    enum Phase: String, Equatable { case review, running, stopped, done
        var name: String { rawValue }
    }

    var phase: Phase {
        if isCompressing { return .running }
        if !hasStarted { return .review }
        return remainingCount > 0 ? .stopped : .done
    }

    var finishedCount: Int { items.filter { $0.state == .finished }.count }
    var skippedCount: Int { items.filter { if case .failed = $0.state { true } else { false } }.count }
    var alreadySmallCount: Int { items.filter { $0.state == .alreadySmall }.count }
    var remainingCount: Int { items.filter { $0.state == .ready }.count }

    func remove(_ item: VideoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        lastRemoved = (item, index)
        save()
    }

    /// The most recent Review removal, so a mis-tap can be undone in place.
    private var lastRemoved: (item: VideoItem, index: Int)?
    var canUndoRemove: Bool { lastRemoved != nil }

    func undoRemove() {
        guard let (item, index) = lastRemoved else { return }
        items.insert(item, at: min(index, items.count))
        lastRemoved = nil
        save()
    }

    /// Put a failed item back in the queue. Resume (or Start) runs it.
    func retry(_ item: VideoItem) {
        guard case .failed = item.state else { return }
        item.state = .ready
        item.progress = 0
        applyEstimate(item)
        save()
    }

    func retryAllFailed() {
        for item in items { if case .failed = item.state { retry(item) } }
    }

    /// Removes files in the working directory that no item refers to — the
    /// half-written export left behind when the app is killed mid-encode.
    /// Returns how many were removed.
    @discardableResult
    nonisolated static func removeOrphans(in directory: URL, keeping: Set<String>) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var removed = 0
        for name in names where !keeping.contains(name) {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    var deletableCount: Int { items.filter(\.canDeleteOriginal).count }

    /// What deleting the deletable originals actually frees (the copies stay).
    var deletableFreedBytes: Int64 {
        items.filter(\.canDeleteOriginal).reduce(0) { $0 + $1.actualSavedBytes }
    }

    /// Items whose originals the delete sheet will keep (§5.2 "aren't included").
    var excludedFromDeleteCount: Int {
        items.filter { !$0.canDeleteOriginal && !$0.originalDeleted }.count
    }

    /// Delete every original whose compressed copy is safely in Photos, with a
    /// single iOS confirmation for the lot.
    @discardableResult
    func deleteAllOriginals() async -> Bool {
        let targets = items.filter { verifiedCopyExists($0) }
        let ids = targets.compactMap(\.assetID)
        guard !ids.isEmpty else { return false }
        let deleted = await PhotoLibrary.deleteOriginals(ids: ids)
        if deleted {
            targets.forEach { $0.originalDeleted = true }
            SavingsStats.update { $0.recordDeleted(ids: ids) }
        }
        save()
        return deleted
    }

    /// Delete the library original. Only callable once the compressed copy is
    /// saved; iOS shows its own confirmation sheet.
    @discardableResult
    func deleteOriginal(_ item: VideoItem) async throws -> Bool {
        guard verifiedCopyExists(item), let assetID = item.assetID else { return false }
        let deleted = try await PhotoLibrary.deleteOriginal(id: assetID)
        item.originalDeleted = deleted
        if deleted { SavingsStats.update { $0.recordDeleted(ids: [assetID]) } }
        save()
        return deleted
    }

    /// Which copy IDs still exist in Photos. Replaced in tests.
    var copyExists: ([String]) -> Set<String> = PhotoLibrary.existingIDs

    /// Asked immediately before any delete: is this item's copy still in
    /// Photos right now? One whose copy is gone (or was never known) loses its
    /// gate and its "ready" entry for good, and is never deleted.
    private func verifiedCopyExists(_ item: VideoItem) -> Bool {
        guard item.canDeleteOriginal, let original = item.assetID else { return false }
        let plan = SavingsStats.deletionPlan(copies: [original: item.savedAssetID],
                                             existing: copyExists(item.savedAssetID.map { [$0] } ?? []))
        guard plan.safe.isEmpty else { return true }
        item.savedToPhotos = false
        item.savedAssetID = nil
        SavingsStats.update { $0.drop(ids: plan.drop) }
        return false
    }

    /// Re-encode one photo to HEIC. Live Photos keep their video half.
    private func compressPhoto(_ item: VideoItem) async throws {
        guard let photo = item.photo, let assetID = item.assetID else {
            item.state = .failed("This photo could not be read.")
            return
        }
        let data = try await PhotoLibrary.imageData(id: assetID)
        let plan = settings.photoPlan(for: photo)
        let basename = (photo.filename as NSString).deletingPathExtension

        let engine = photoEngine
        let output = try await Task.detached(priority: .userInitiated) {
            try engine.compress(data: data, plan: plan, basename: basename)
        }.value

        item.outputURL = output
        item.outputSize = (try? FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? Int64) ?? nil
        item.state = .finished
        item.progress = 1.0
    }

    /// A large export that runs out of disk fails deep inside AVFoundation with
    /// an opaque message, so check first and say something useful.
    static func freeSpaceShortfall(for item: VideoItem) -> String? {
        guard let needed = item.estimate?.estimatedBytes, needed > 0 else { return nil }
        let path = VideoCompressorEngine.workingDirectory.path
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attributes[.systemFreeSize] as? Int64 else { return nil }

        // Leave headroom; an export that fills the disk destabilises the device.
        let required = needed + 500_000_000
        guard free < required else { return nil }

        let short = ByteCountFormatter.string(fromByteCount: required - free, countStyle: .file)
        return "Not enough free space — about \(short) more is needed."
    }

    /// Deletes our working files. Never touches a source file.
    func clear() {
        for item in items {
            if let output = item.outputURL {
                try? FileManager.default.removeItem(at: output)
            }
        }
        items.removeAll()
        hasStarted = false
        save()
    }

    private func reestimateAll() {
        for item in items { applyEstimate(item) }
    }

    /// Fresh estimate; a waiting item that can't save enough is set aside as
    /// already small before any work is spent on it (QA B1b).
    private func applyEstimate(_ item: VideoItem) {
        guard [.pending, .ready, .alreadySmall].contains(item.state) else { return }
        item.estimate = estimate(for: item) ?? item.estimate
        item.state = item.estimate?.isWorthwhile == false ? .alreadySmall : .ready
    }

    /// The safety net (QA B1c): estimates are guesses, the output size is not.
    /// A copy that isn't at least 10% smaller is deleted, never saved to
    /// Photos, and its original never becomes deletable. An unknown (nil or
    /// zero) size on either side is unproven, so that copy is discarded too.
    func discardIfNotSmaller(_ item: VideoItem) -> Bool {
        guard item.state == .finished else { return false }   // failed: nothing to judge
        if let size = item.outputSize, size > 0, item.sourceBytes > 0,
           Double(size) < Double(item.sourceBytes) * (1 - SavingsEstimator.worthwhileThreshold) {
            return false
        }
        if let output = item.outputURL { try? FileManager.default.removeItem(at: output) }
        item.outputURL = nil
        item.outputSize = nil
        item.progress = 0
        item.state = .alreadySmall
        return true
    }

    /// Batch Done (E7/E8): unstarted items go back to the Library selection,
    /// everything else leaves it, and the Library reloads.
    func finishBatch() {
        let unstarted = Set(items.filter { $0.state == .ready }.compactMap(\.assetID))
        let handled = Set(items.compactMap(\.assetID)).subtracting(unstarted)
        selection.ids.subtract(handled)
        selection.ids.formUnion(unstarted)
        clear()
        libraryGeneration += 1
    }

    /// The saving this item is expected to bring under the current settings.
    func estimate(for item: VideoItem, settings: CompressionSettings? = nil) -> SavingsEstimate? {
        let settings = settings ?? self.settings
        if let photo = item.photo {
            let plan = settings.photoPlan(for: photo)
            let saved = max(0, photo.fileSize - plan.estimatedBytes)
            let fraction = photo.fileSize > 0 ? Double(saved) / Double(photo.fileSize) : 0
            return SavingsEstimate(estimatedBytes: plan.estimatedBytes, savedBytes: saved,
                                   savedFraction: fraction,
                                   isWorthwhile: fraction >= SavingsEstimator.worthwhileThreshold)
        }
        guard let metadata = item.metadata else { return nil }
        return SavingsEstimator.estimate(for: metadata, plan: settings.videoPlan(for: metadata))
    }
}
