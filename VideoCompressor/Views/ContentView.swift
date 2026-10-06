import SwiftUI

/// Root: Library, pushing the one Batch screen (spec §11.2).
struct ContentView: View {
    @State private var store = BatchStore(saveURL: BatchSnapshot.defaultURL)
    @State private var showBatch = false
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var selected: (videos: [LibraryVideo], photos: [LibraryPhoto]) = ([], [])
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("videoPreset") private var videoPreset: VideoPreset = .balanced
    @AppStorage("targetSize") private var target: TargetSize = .mb200
    @AppStorage("photoQuality") private var photoQuality: PhotoQuality = .balanced
    @AppStorage("downscaleLargePhotos") private var downscaleLargePhotos = true

    private var settings: CompressionSettings {
        CompressionSettings(videoPreset: videoPreset, target: target,
                            photoQuality: photoQuality, downscaleLargePhotos: downscaleLargePhotos)
    }

    var body: some View {
        NavigationStack {
            LibraryView(
                selection: $store.selection,
                onReview: { videos, photos in
                    // A finished or unstarted batch is replaced; a running one is added to.
                    if !store.isCompressing { store.clear() }
                    // Items exist before the push, so Batch never opens empty
                    // or half-built (QA M1); codec probing refines them after.
                    store.enqueue(videos: videos, photos: photos)
                    showBatch = true
                    Task { await store.refine(videos: videos) }
                },
                runningStatus: runningStatus,
                onShowBatch: { showBatch = true },
                onShowSettings: { showSettings = true },
                onShowHelp: { showHelp = true },
                onSelectedChange: { selected = ($0, $1) },
                settings: settings,
                reloadToken: store.libraryGeneration)
            .navigationDestination(isPresented: $showBatch) {
                BatchView(store: store,
                          onShowSettings: { showSettings = true },
                          onClose: { showBatch = false })
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(videoPreset: $videoPreset, target: $target,
                         photoQuality: $photoQuality, downscaleLargePhotos: $downscaleLargePhotos,
                         isRunning: store.isCompressing,
                         estimateCount: estimateCount, estimate: estimate)
        }
        .sheet(isPresented: $showHelp) { HelpView() }
        .task {
            store.settings = settings
            store.restoreFromDisk()
            // A batch from last time (stopped, or done with originals to
            // delete): take the user straight back to it.
            if !store.items.isEmpty { showBatch = true }
        }
        .onChange(of: settings) { store.settings = settings }
        .onChange(of: store.selection) { store.save() }
        .onChange(of: scenePhase) { if scenePhase != .active { store.save() } }
    }

    /// What the Settings sheet quotes: the unstarted batch if there is one,
    /// else the Library selection.
    private var readyItems: [VideoItem] { store.items.filter { $0.state == .ready } }
    private var estimateCount: Int {
        readyItems.isEmpty ? selected.videos.count + selected.photos.count : readyItems.count
    }
    private func estimate(_ s: CompressionSettings) -> Int64 {
        if readyItems.isEmpty {
            return LibrarySelection.estimatedFreed(videos: selected.videos, photos: selected.photos, settings: s)
        }
        return readyItems.reduce(0) { $0 + (store.estimate(for: $1, settings: s)?.savedBytes ?? 0) }
    }

    private var runningStatus: String? {
        guard store.isCompressing else { return nil }
        let freed = ByteCountFormatter.string(fromByteCount: store.totalSavedBytes, countStyle: .file)
        return "Compressing \(min(store.finishedCount + 1, store.items.count)) of \(store.items.count) · \(freed) freed"
    }
}

#Preview {
    ContentView()
}
