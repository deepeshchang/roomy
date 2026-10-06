import Foundation

/// What survives the app being killed: the queue and the Library selection,
/// as a small JSON file. Settings are not here — they live in @AppStorage.
struct BatchSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        enum State: String, Codable { case ready, finished, failed, alreadySmall }

        var assetID: String
        var kind: MediaKind
        var state: State
        var failure: String?
        var video: VideoMetadata?
        var photo: LibraryPhoto?
        var outputSize: Int64?
        var savedAssetID: String?
        var savedToPhotos = false
        var originalDeleted = false
    }

    var version = 1
    var started = false
    var items: [Item] = []
    var selection: [String] = []

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("batch.json")
    }
}

private extension BatchSnapshot {
    func with(started: Bool) -> Self { var s = self; s.started = started; return s }
}

extension BatchStore {
    /// File-picked items (no asset ID) are not saved: their temporary copies
    /// don't outlive the process.
    var snapshot: BatchSnapshot {
        BatchSnapshot(items: items.compactMap { item in
            guard let assetID = item.assetID else { return nil }
            var entry = BatchSnapshot.Item(assetID: assetID, kind: item.kind, state: .ready,
                                           video: item.metadata, photo: item.photo,
                                           outputSize: item.outputSize,
                                           savedAssetID: item.savedAssetID,
                                           savedToPhotos: item.savedToPhotos,
                                           originalDeleted: item.originalDeleted)
            switch item.state {
            // Only a copy that reached Photos counts: an unsaved output in the
            // cache may be gone after relaunch, so that item is redone.
            case .finished where item.savedToPhotos: entry.state = .finished
            case .failed(let why): entry.state = .failed; entry.failure = why
            case .alreadySmall: entry.state = .alreadySmall
            default: break   // compressing / downloading / ready → ready
            }
            return entry
        }, selection: selection.ids.sorted()).with(started: hasStarted)
    }

    func restore(_ snapshot: BatchSnapshot) {
        items = snapshot.items.map { entry in
            let item = VideoItem(sourceURL: nil, assetID: entry.assetID,
                                 kind: entry.kind, photo: entry.photo)
            item.metadata = entry.video
            item.outputSize = entry.outputSize
            item.savedAssetID = entry.savedAssetID
            item.savedToPhotos = entry.savedToPhotos
            item.originalDeleted = entry.originalDeleted
            switch entry.state {
            case .ready: item.state = .ready
            case .finished: item.state = .finished; item.progress = 1
            case .alreadySmall: item.state = .alreadySmall
            case .failed: item.state = .failed(entry.failure ?? "This item couldn't be compressed.")
            }
            item.estimate = estimate(for: item)
            return item
        }
        selection = LibrarySelection(ids: Set(snapshot.selection))
        hasStarted = snapshot.started
    }

    /// Atomic write, so a kill mid-save leaves the previous file intact.
    func save() {
        guard let saveURL else { return }
        do {
            try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: saveURL, options: .atomic)
        } catch {
            // Losing the saved queue is an inconvenience, not data loss: the
            // originals and any saved copies are in Photos regardless.
        }
    }

    func restoreFromDisk() {
        defer { removeOrphanedWork() }
        guard let saveURL, let data = try? Data(contentsOf: saveURL),
              let snapshot = try? JSONDecoder().decode(BatchSnapshot.self, from: data) else { return }
        restore(snapshot)
    }

    /// A kill mid-encode leaves a half-written file that nothing refers to.
    /// Skipped when the app is hosting unit tests, which write into the same
    /// working directory while the host app is still launching.
    private func removeOrphanedWork() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let keep = Set(items.compactMap { $0.outputURL?.lastPathComponent })
        BatchStore.removeOrphans(in: VideoCompressorEngine.workingDirectory, keeping: keep)
        // Live Photo paired clips (with GPS) are only needed mid-save.
        BatchStore.removeOrphans(in: PhotoLibrary.importedDirectory, keeping: [])
    }
}
