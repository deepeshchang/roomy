import AVKit
import SwiftUI

/// Before/after peek (spec §13). One player and a segmented switch, not two
/// side-by-side players: two 1080p videos on a phone are each too small to
/// judge, and AVPlayer instances are expensive. Photos get the same layout.
struct CompareView: View {
    let item: VideoItem
    let store: BatchStore

    @State private var showingCompressed = true
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var holding = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

    private var isPhoto: Bool { item.kind == .photo }
    /// Hold-to-compare shows the original while pressed.
    private var showingOriginal: Bool { !showingCompressed || holding }
    private var visibleAssetID: String? { showingOriginal ? item.assetID : item.savedAssetID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    media
                    Picker("Version", selection: $showingCompressed) {
                        Text(item.originalDeleted ? "Original (Deleted)" : "Original").tag(false)
                        Text("Compressed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(item.originalDeleted)
                    .padding(.horizontal, 16)
                    facts.padding(.horizontal, 16)
                    if item.canDeleteOriginal {
                        Button("Delete Original", role: .destructive) {
                            Task { _ = try? await store.deleteOriginal(item) }
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("compare.done")
                }
            }
            .task(id: showingCompressed) { await switchVideo() }
            .task(id: visibleAssetID) { await loadImage() }
            .onDisappear { player?.pause(); player = nil }
        }
        .presentationDetents([.large])
    }

    // MARK: Media

    @ViewBuilder private var media: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if isPhoto {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom * pinch)   // shared across both sides
                        .gesture(MagnifyGesture()
                            .onChanged { pinch = $0.magnification }
                            .onEnded { zoom = max(1, zoom * $0.magnification); pinch = 1 })
                        .onLongPressGesture(minimumDuration: 0, perform: {},
                                            onPressingChanged: { holding = $0 })
                        .accessibilityAction(named: "Show Original") { showingCompressed = false }
                } else {
                    poster
                }
            } else if let player {
                VideoPlayer(player: player)
            } else {
                poster
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(.black.opacity(0.4)))
                    }
                    .onTapGesture { Task { await startPlaying(at: .zero) } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Play")
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
    }

    private var poster: some View {
        GeometryReader { geo in
            ThumbnailImage(assetID: visibleAssetID,
                           fileURL: showingOriginal ? item.sourceURL : item.outputURL,
                           side: geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var aspect: CGFloat {
        let w = item.photo?.width ?? item.metadata?.width ?? 16
        let h = item.photo?.height ?? item.metadata?.height ?? 9
        return h > 0 && w > 0 ? CGFloat(w) / CGFloat(h) : 16 / 9
    }

    /// Keeps the playback position across sides so the same frame is compared.
    private func switchVideo() async {
        guard !isPhoto, let old = player else { return }
        let time = old.currentTime()
        old.pause()
        await startPlaying(at: time)
    }

    private func startPlaying(at time: CMTime) async {
        guard let next = await loadPlayer() else { player = nil; return }
        await next.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        player = next
        next.play()
    }

    /// The compressed copy is either still in the cache or already moved into
    /// Photos; the original is read from the library in place.
    private func loadPlayer() async -> AVPlayer? {
        if showingCompressed {
            if let url = item.outputURL { return AVPlayer(url: url) }
            if let id = item.savedAssetID,
               let box = try? await PhotoLibrary.avAsset(id: id, allowNetwork: false) {
                return AVPlayer(playerItem: AVPlayerItem(asset: box.asset))
            }
            return nil
        }
        if let asset = item.sourceAsset {
            return AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        if item.originalDeleted { return nil }
        if let id = item.assetID,
           let box = try? await PhotoLibrary.avAsset(id: id, allowNetwork: true) {
            return AVPlayer(playerItem: AVPlayerItem(asset: box.asset))
        }
        return item.sourceURL.map { AVPlayer(url: $0) }
    }

    /// Visible side only. reuses Thumbnails at a large side rather
    /// than a separate PHImageManagerMaximumSize path; raise the side if
    /// pixel-peeping 48MP shots ever needs it.
    private func loadImage() async {
        guard isPhoto else { return }
        if !showingOriginal, let url = item.outputURL {
            image = UIImage(contentsOfFile: url.path)
        } else if let id = visibleAssetID {
            image = await Thumbnails.image(for: id, size: 1600)
        } else {
            image = nil
        }
    }

    // MARK: Facts

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Original").foregroundStyle(.secondary)
                Text(bytes(item.sourceBytes))
                Text(originalSpec)
            }
            if let out = item.outputSize {
                GridRow {
                    Text("Compressed").foregroundStyle(.secondary)
                    Text(bytes(out))
                    Text(compressedSpec).foregroundStyle(resolutionDropped ? .orange : .primary)
                }
                GridRow {
                    Text("Saved").foregroundStyle(.secondary)
                    Text("\(bytes(item.actualSavedBytes)) (\(savedPercent)%)")
                        .foregroundStyle(.green)
                        .gridCellColumns(2)
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(factsLabel)
    }

    private var originalSize: (Int, Int) {
        (item.photo?.width ?? item.metadata?.width ?? 0, item.photo?.height ?? item.metadata?.height ?? 0)
    }

    /// The compressed frame size as planned. derived from the plan,
    /// not read back from the output file; matches unless the target changed mid-run.
    private var compressedSize: (Int, Int) {
        if let photo = item.photo {
            let plan = store.settings.photoPlan(for: photo)
            guard let cap = plan.maxLongEdge else { return originalSize }
            return CompressionPlan.fit(width: photo.width, height: photo.height, longEdgeCap: cap)
        }
        guard let metadata = item.metadata else { return originalSize }
        let plan = store.settings.videoPlan(for: metadata)
        return (plan.width, plan.height)
    }

    private var resolutionDropped: Bool {
        max(compressedSize.0, compressedSize.1) < max(originalSize.0, originalSize.1)
    }

    private var originalSpec: String { spec(originalSize) }
    private var compressedSpec: String { spec(compressedSize) }

    private func spec(_ size: (Int, Int)) -> String {
        let edge = min(size.0, size.1)
        let res = edge >= 2160 ? "4K" : edge > 0 ? "\(edge)p" : ""
        if isPhoto { return "\(size.0)×\(size.1)" }
        return [res, item.metadata?.formattedDuration ?? ""].filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var savedPercent: Int {
        item.sourceBytes > 0 ? Int(Double(item.actualSavedBytes) / Double(item.sourceBytes) * 100) : 0
    }

    private var factsLabel: String {
        let full: (Int64) -> String = {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        guard let out = item.outputSize else { return "Original \(full(item.sourceBytes))" }
        return "Original \(full(item.sourceBytes)), compressed \(full(out)), saved \(full(item.actualSavedBytes)), \(savedPercent) percent"
    }

    private var title: String {
        let date = item.photo?.creationDate
            ?? item.assetID.flatMap { PhotoLibrary.originalInfo(id: $0)?.creationDate }
        return date?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
