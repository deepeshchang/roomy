import Photos
import PhotosUI
import SwiftUI

/// The app's root: the library as a largest-first thumbnail mosaic with
/// modeless selection and a persistent running total (spec §1, §3, §6, §11.3).
struct LibraryView: View {
    /// Owned by the store so it is saved across launches.
    @Binding var selection: LibrarySelection
    /// Called when the user taps the bottom bar's Compress button.
    let onReview: (_ videos: [LibraryVideo], _ photos: [LibraryPhoto]) -> Void
    /// Non-nil while a batch is running; LibraryView shows the compact status row from the spec and calls onShowBatch when tapped.
    let runningStatus: String?
    let onShowBatch: () -> Void
    let onShowSettings: () -> Void
    let onShowHelp: () -> Void
    /// Reports the selected items so Settings can quote a live estimate.
    let onSelectedChange: (_ videos: [LibraryVideo], _ photos: [LibraryPhoto]) -> Void
    /// The user's settings, so the bottom bar's estimate matches what the batch will do.
    var settings = CompressionSettings()
    /// Changes when a batch closes; the library reloads so compressed items
    /// and new copies show up without a relaunch.
    var reloadToken = 0

    private enum Access { case unknown, notAsked, denied, limited, full }

    @State private var access: Access = .unknown
    @State private var loadingVideos = true
    @State private var loadingPhotos = true
    @State private var progress = LoadProgress()
    @State private var showProgress = false
    @State private var generation = LoadGeneration()
    @State private var photosTask: Task<Void, Never>?
    /// Per-tab: the Videos tab is usable as soon as videos finish, even if photos are still scanning.
    private var isLoading: Bool { mediaKind == .video ? loadingVideos : loadingPhotos }
    @State private var allVideos: [LibraryVideo] = []
    @State private var allPhotos: [LibraryPhoto] = []
    @AppStorage("libraryMediaKind") private var mediaKind: MediaKind = .video
    /// Off by default: on a library of shared or already-compressed videos,
    /// on hid everything and the app opened on "All done" (QA B4).
    @AppStorage("hideCompressed") private var hideCompressed = false
    @AppStorage("librarySort") private var sort: LibrarySort = .largest
    /// Each type keeps its own size preset (PRD §2).
    @AppStorage("sizeFilter.video") private var minVideoBytes = 0
    @AppStorage("sizeFilter.photo") private var minPhotoBytes = 0
    /// Lifetime savings; @AppStorage so a write from the batch or a reset in
    /// Settings shows here at once.
    @AppStorage(SavingsStats.key) private var savingsData: Data?
    @State private var showSavings = false
    @State private var prunedNotice: Int?

    // Drag-to-select. Frames are in the grid's own (scrolling) coordinate
    // space, so they stay valid as the user scrolls.
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragStartID: String?
    @State private var dragBase: Set<String> = []

    @Environment(\.openURL) private var openURL

    // MARK: Derived

    private var handled: Set<String> { CompressionLedger().handledIDs }
    private var stats: SavingsStats { SavingsStats.decode(savingsData) }
    private func query(_ kind: MediaKind) -> LibraryQuery {
        LibraryQuery(sort: sort, minBytes: Int64(kind == .video ? minVideoBytes : minPhotoBytes),
                     hideCompressed: hideCompressed)
    }
    private var minBytes: Binding<Int> { mediaKind == .video ? $minVideoBytes : $minPhotoBytes }
    private var videos: [LibraryVideo] { query(.video).apply(allVideos, handled: handled) }
    private var photos: [LibraryPhoto] { query(.photo).apply(allPhotos, handled: handled) }
    private var visible: [LibrarySelection.Item] {
        mediaKind == .video ? videos.map { ($0.id, $0.fileSize) } : photos.map { ($0.id, $0.fileSize) }
    }
    private var selectedVideos: [LibraryVideo] { allVideos.filter { selection.ids.contains($0.id) } }
    private var selectedPhotos: [LibraryPhoto] { allPhotos.filter { selection.ids.contains($0.id) } }
    private var noun: String { mediaKind == .video ? "video" : "photo" }
    private var typeIsEmpty: Bool { mediaKind == .video ? allVideos.isEmpty : allPhotos.isEmpty }

    var body: some View {
        // No NavigationStack here: ContentView owns the one stack (QA M4).
        content
            .navigationTitle(selection.ids.isEmpty ? "Roomy" : "\(selection.ids.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if access != .denied && access != .notAsked && (!selection.ids.isEmpty || runningStatus != nil) {
                    bottomBar
                }
            }
            .overlay(alignment: .top) { prunedOverlay }
            .sheet(isPresented: $showSavings) { SavingsSheet(stats: stats) }
        .task(id: reloadToken) { await start() }
        .onChange(of: selection, initial: true) { onSelectedChange(selectedVideos, selectedPhotos) }
        .onChange(of: isLoading) { onSelectedChange(selectedVideos, selectedPhotos) }
        .onChange(of: [hideCompressed ? 1 : 0, minVideoBytes, minPhotoBytes]) {
            let removed = selection.prune(keeping: Set(videos.map(\.id) + photos.map(\.id)))
            if removed > 0 { showPruned(removed) }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch access {
        case .unknown:
            skeleton
        case .notAsked:
            ContentUnavailableView {
                Label("See your largest files", systemImage: "photo.on.rectangle")
            } description: {
                Text("Roomy needs to see your library to find the videos and photos taking the most space. Nothing is uploaded.")
            } actions: {
                Button { Task { await load() } } label: {
                    Text("Continue").foregroundStyle(.background)
                }
                .accessibilityIdentifier("library.continueAccess")
                    .buttonStyle(.borderedProminent)
                Button("Not Now") { access = .denied }
            }
        case .denied:
            ScrollView {
                VStack(spacing: 12) {
                    savingsCard
                    ContentUnavailableView {
                        Label("Photos Access Needed", systemImage: "lock")
                    } description: {
                        Text("Roomy needs your photo library to find large videos. Nothing leaves your iPhone.")
                    } actions: {
                        // After "Not Now" iOS has never been asked, so Settings has no
                        // Photos switch for Roomy yet — sending people there was a dead
                        // end. Ask instead; only point at Settings once iOS has an answer.
                        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                            Button { Task { await load() } } label: {
                                Text("Allow Access").foregroundStyle(.background)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("library.allowAccess")
                        } else {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        case .limited, .full:
            library
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    private var library: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 12) {
                    if access == .limited { limitedBanner }
                    savingsCard
                    if selection.ids.isEmpty && !typeIsEmpty { winsCard }
                    typePicker
                    if !typeIsEmpty || isLoading {
                        chips
                        resultsLine
                    }
                }
                .padding(.horizontal, 16)
                if isLoading {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(0..<9, id: \.self) { _ in
                            Color(.secondarySystemFill).aspectRatio(1, contentMode: .fit)
                        }
                    }
                } else if visible.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
        .accessibilityIdentifier("library.grid")
        .background(Color(.systemBackground))
    }

    private var grid: some View {
        let cutoff = LibraryQuery.largeCutoff(
            mediaKind == .video ? allVideos.map(\.fileSize) : allPhotos.map(\.fileSize))
        return LazyVGrid(columns: columns, spacing: 2) {
            if mediaKind == .video {
                ForEach(videos) { cell(for: $0, cutoff: cutoff) }
            } else {
                ForEach(photos) { cell(for: $0, cutoff: cutoff) }
            }
        }
        .coordinateSpace(.named(Self.gridSpace))
        .gesture(PressDragRecognizer(
            coordinateSpace: Self.gridSpace,
            onBegan: { point in
                dragStartID = id(at: point)
                dragBase = selection.ids
                paint(to: point)
            },
            onChanged: { paint(to: $0) },
            onEnded: { dragStartID = nil }))
    }

    // MARK: Header blocks (library-v2 spec §2)

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// Compact on purpose: a full row of thumbnails must show without
    /// scrolling on a 14 Pro Max (owner review of the mockups).
    private var savingsCard: some View {
        let s = stats
        let counts = [s.videoCount > 0 ? "\(s.videoCount.formatted()) video\(s.videoCount == 1 ? "" : "s")" : nil,
                      s.photoCount > 0 ? "\(s.photoCount.formatted()) photo\(s.photoCount == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let ready = s.readyBytes > 0 ? " \(bytes(s.readyBytes)) ready to free." : ""
        return Button { showSavings = true } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if s.savedBytes > 0 {
                        Text("Roomy has saved you").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        Text(bytes(s.savedBytes)).font(.title2.bold()).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("across \(counts)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Nothing saved yet.").font(.headline)
                        Text("Start with your biggest wins below.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if s.readyBytes > 0 {
                    Text("\(bytes(s.readyBytes)) ready to free")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.trailing)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.savedBytes > 0
            ? "Roomy has saved you \(bytes(s.savedBytes)), across \(counts)." + ready
            : "Nothing saved yet." + ready)
        .accessibilityHint("Shows details.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("library.savingsCard")
    }

    private var wins: (videos: [LibraryVideo], photos: [LibraryPhoto]) {
        mediaKind == .video ? (LibraryQuery.biggestWins(allVideos, handled: handled), [])
                            : ([], LibraryQuery.biggestWins(allPhotos, handled: handled))
    }

    @ViewBuilder private var winsCard: some View {
        let w = wins
        let ids = w.videos.map(\.id) + w.photos.map(\.id)
        let total = (w.videos.map(\.fileSize) + w.photos.map(\.fileSize)).reduce(0, +)
        let estimate = LibrarySelection.estimatedFreed(videos: w.videos, photos: w.photos, settings: settings)
        let floor: Int64 = mediaKind == .video ? 50_000_000 : 10_000_000
        if isLoading || estimate >= floor {
            let n = ids.count
            let shared = access == .limited ? "visible " : ""
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(n == 1 ? "Your largest \(shared)\(noun): \(bytes(total))"
                                : "Your \(n) largest \(shared)\(noun)s: \(bytes(total))")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("About \(bytes(estimate)) could be freed")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                .redacted(reason: isLoading ? .placeholder : [])
                Spacer(minLength: 0)
                Button {
                    bulk { selection.ids = Set(ids) }
                } label: {
                    Text(n == 1 ? "Select It" : "Select These \(n)").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
                .accessibilityIdentifier("library.selectWins")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    private var typePicker: some View {
        Picker("Type", selection: $mediaKind) {
            Text(loadingVideos ? "Videos" : "Videos  \(bytes(allVideos.reduce(0) { $0 + $1.fileSize }))").tag(MediaKind.video)
            Text(loadingPhotos ? "Photos" : "Photos  \(bytes(allPhotos.reduce(0) { $0 + $1.fileSize }))").tag(MediaKind.photo)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("library.mediaPicker")
    }

    /// Sized to fit on one line on a 6.1" phone; still scrolls sideways if
    /// Dynamic Type makes it wider (owner review: no clipped chip).
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Largest First").tag(LibrarySort.largest)
                        Text("Newest First").tag(LibrarySort.newest)
                    }
                    .pickerStyle(.inline)
                } label: {
                    chip(active: false) {
                        Image(systemName: sort == .largest ? "arrow.down" : "calendar")
                        Text(sort == .largest ? "Largest" : "Newest")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                }
                .accessibilityLabel("Sort, \(sort == .largest ? "Largest" : "Newest") first")
                .tint(.primary)
                .accessibilityIdentifier("library.sortChip")

                Menu {
                    Picker("Size", selection: minBytes) {
                        ForEach(LibraryQuery.sizeOptions(for: mediaKind), id: \.self) {
                            Text(sizeTitle(Int($0))).tag(Int($0))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    chip(active: minBytes.wrappedValue > 0) {
                        Text(minBytes.wrappedValue > 0 ? sizeTitle(minBytes.wrappedValue) : "Size: All")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                }
                .accessibilityLabel("Size filter, \(sizeTitle(minBytes.wrappedValue))")
                .tint(.primary)
                .accessibilityIdentifier("library.sizeChip")

                Button { hideCompressed.toggle() } label: {
                    chip(active: hideCompressed) {
                        Image(systemName: hideCompressed ? "checkmark.circle.fill" : "circle")
                        Text("Hide Compressed")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide compressed")
                .accessibilityValue(hideCompressed ? "on" : "off")
                .accessibilityAddTraits(hideCompressed ? .isSelected : [])
                .accessibilityIdentifier("library.hideCompressed")
            }
        }
        .scrollClipDisabled()
    }

    private func sizeTitle(_ n: Int) -> String { n == 0 ? "All" : "Over \(bytes(Int64(n)))" }

    private func chip(active: Bool, @ViewBuilder _ label: () -> some View) -> some View {
        HStack(spacing: 4) { label() }
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .foregroundStyle(active ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                        in: Capsule())
            .contentShape(Capsule())
    }

    private var resultsLine: some View {
        HStack {
            if isLoading {
                if showProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.label)
                        ProgressView(value: progress.fraction)
                    }
                    .accessibilityIdentifier("library.loadingProgress")
                }
            } else {
                let n = visible.count
                let total = bytes(visible.reduce(0) { $0 + $1.bytes })
                let allCompressed = !hideCompressed && n > 0 && wins.videos.isEmpty && wins.photos.isEmpty
                Text("\(n.formatted()) \(noun)\(n == 1 ? "" : "s") · \(total)\(allCompressed ? " · all compressed" : "")")
                    .accessibilityIdentifier("library.results")
            }
            Spacer()
            if query(mediaKind).isFiltered && !isLoading {
                Button("Clear Filters", action: clearFilters).accessibilityIdentifier("library.clearFilters")
            }
        }
        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
    }

    private func clearFilters() {
        minVideoBytes = 0
        minPhotoBytes = 0
        hideCompressed = false
    }

    private var limitedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Roomy can see \((mediaKind == .video ? allVideos.count : allPhotos.count).formatted()) of your \(noun)s.")
                .font(.subheadline)
            HStack(spacing: 16) {
                Button("Allow Full Access") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Choose More") { presentLimitedPicker() }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var emptyState: some View {
        let q = query(mediaKind)
        if typeIsEmpty {
            ContentUnavailableView {
                Label(mediaKind == .video ? "No Videos" : "No Photos",
                      systemImage: mediaKind == .video ? "video.slash" : "photo.on.rectangle")
            } description: {
                Text("There are no \(noun)s on this iPhone.")
            }
        } else if hideCompressed && q.minBytes == 0 {
            ContentUnavailableView {
                Label("All Compressed", systemImage: "checkmark.seal")
            } description: {
                Text("Every \(noun) here is already compressed.")
            } actions: {
                Button("Show Compressed") { hideCompressed = false }
                    .accessibilityIdentifier("library.showAll")
            }
        } else {
            ContentUnavailableView {
                Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(q.minBytes > 0 ? "No \(noun)s \(sizeTitle(Int(q.minBytes)).lowercased())."
                                    : "No \(noun)s match these filters.")
            } actions: {
                Button("Clear Filters", action: clearFilters)
            }
        }
    }

    /// §6.1: shimmering placeholder cells, never a bare spinner.
    private var skeleton: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<18, id: \.self) { _ in
                    Color(.secondarySystemFill).aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .phaseAnimator([0.6, 1.0]) { view, phase in
            view.opacity(phase)
        } animation: { _ in .easeInOut(duration: 1.2) }
        .scrollDisabled(true)
        .accessibilityLabel("Reading your library")
    }

    // MARK: Cells

    private func cell(for video: LibraryVideo, cutoff: Int64) -> some View {
        var badges: [LibraryGridCell.Badge] = []
        if LibraryQuery.isCompressed(video, handled: handled) { badges.append(.symbol("checkmark.seal.fill")) }
        var label = "Video"
        if let date = video.creationDate { label += ", \(date.formatted(date: .long, time: .omitted))" }
        label += ", \(spokenDuration(video.duration)), \(video.formattedSize)"
        return selectable(video.id,
                          LibraryGridCell(assetID: video.id, leadingText: video.formattedDuration,
                                          bytes: video.fileSize, badges: badges,
                                          isSelected: selection.ids.contains(video.id),
                                          accessibilityText: label,
                                          isLarge: LibraryQuery.isLarge(video.fileSize, cutoff: cutoff)))
    }

    private func cell(for photo: LibraryPhoto, cutoff: Int64) -> some View {
        var badges: [LibraryGridCell.Badge] = []
        if photo.isLivePhoto { badges.append(.symbol("livephoto")) }
        if photo.isRAW { badges.append(.text("RAW")) }
        if LibraryQuery.isCompressed(photo, handled: handled) { badges.append(.symbol("checkmark.seal.fill")) }
        let mp = "\(Int((Double(photo.width * photo.height) / 1_000_000).rounded())) MP"
        var label = "Photo"
        if let date = photo.creationDate { label += ", \(date.formatted(date: .long, time: .omitted))" }
        label += ", \(mp.replacingOccurrences(of: "MP", with: "megapixels")), \(photo.formattedSize)"
        if photo.isLivePhoto { label += ", Live Photo" }
        if photo.isRAW { label += ", RAW" }
        return selectable(photo.id,
                          LibraryGridCell(assetID: photo.id, leadingText: mp,
                                          bytes: photo.fileSize, badges: badges,
                                          isSelected: selection.ids.contains(photo.id),
                                          accessibilityText: label,
                                          isLarge: LibraryQuery.isLarge(photo.fileSize, cutoff: cutoff)))
    }

    static let gridSpace = "libraryGrid"

    /// Press and hold a cell, then drag across others to paint a selection,
    /// like Photos. Starting on a selected cell deselects instead.
    private func paint(to point: CGPoint) {
        guard let start = dragStartID, let current = id(at: point) else { return }
        selection.drag(from: start, to: current, in: visible, base: dragBase)
    }

    private func id(at point: CGPoint) -> String? {
        visible.first { cellFrames[$0.id]?.contains(point) == true }?.id
    }

    private func selectable(_ id: String, _ cell: LibraryGridCell) -> some View {
        cell
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: {
                cellFrames[id] = $0
            }
            .onTapGesture { selection.toggle(id) }
            .accessibilityAction { selection.toggle(id) }
            .accessibilityAction(named: "Select from here to end") { selection.selectFrom(id, of: visible) }
    }

    // MARK: Toolbar

    /// While selecting, the bar holds only selection controls (as in Photos):
    /// Select menu leading, Done trailing. Settings and Help return when the
    /// selection is cleared — five controls around "3 Selected" was cramped.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selection.ids.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: onShowSettings)
                    .accessibilityIdentifier("library.settingsButton")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Help", systemImage: "questionmark.circle", action: onShowHelp)
                    .accessibilityIdentifier("library.helpButton")
            }
            ToolbarItem(placement: .topBarTrailing) { selectMenu }
        } else {
            ToolbarItem(placement: .topBarLeading) { selectMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { bulk { selection.deselectAll() } }
                    .bold()
                    .accessibilityIdentifier("library.doneSelecting")
            }
        }
    }

    private var selectMenu: some View {
        Menu("Select") {
            Section {
                ForEach([25, 50, 100], id: \.self) { n in
                    Button("Top \(n)") { bulk { selection.selectTop(n, of: visible) } }
                }
                Button("Everything Over 1 GB") { bulk { selection.selectOver(1_000_000_000, of: visible) } }
                Button("All Visible (\(visible.count))") { bulk { selection.selectTop(visible.count, of: visible) } }
                Button("Deselect All") { bulk { selection.deselectAll() } }
            } footer: {
                Text(sort == .largest ? "Largest first, so Top 50 is the 50 biggest shown."
                                      : "Newest first, so Top 50 is the 50 newest shown.")
            }
        }
        .disabled(isLoading || access == .denied || access == .notAsked)
        .accessibilityIdentifier("library.selectMenu")
    }

    private func bulk(_ change: () -> Void) {
        withAnimation(.easeOut(duration: 0.2), change)
    }

    // MARK: Bottom bar (§3.3, §11.3)

    private var bottomBar: some View {
        let videos = selectedVideos, photos = selectedPhotos
        let count = videos.count + photos.count
        let bytes = (videos.map(\.fileSize) + photos.map(\.fileSize)).reduce(0, +)
        // Estimated at the user's own target, passed in from ContentView.
        let freed = LibrarySelection.estimatedFreed(videos: videos, photos: photos, settings: settings)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let freedText = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)

        return VStack(spacing: 8) {
            if let runningStatus {
                Button(action: onShowBatch) {
                    HStack {
                        Text(runningStatus).monospacedDigit()
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
                .tint(.primary)
                .accessibilityIdentifier("library.runningStatus")
            }
            if count > 0 {
                HStack {
                    Text("\(count) selected · \(size)")
                    Spacer()
                    Text("≈ \(freedText) to free").foregroundStyle(.green)
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: selection)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count) selected, \(size), about \(freedText) to free")
            }

            if count > 0 {
            Button {
                onReview(videos, photos)
            } label: {
                Text(buttonTitle(count))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(count == 0 || isLoading ? AnyShapeStyle(.secondary) : AnyShapeStyle(.background))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(count == 0 || isLoading)
            .accessibilityIdentifier("library.compressButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func buttonTitle(_ count: Int) -> String {
        if runningStatus != nil { return "Add \(count) to Batch" }
        let noun = selectedPhotos.isEmpty ? "Video" : selectedVideos.isEmpty ? "Photo" : "Item"
        return count == 1 ? "Compress 1 \(noun)" : "Compress \(count) \(noun)s"
    }

    @ViewBuilder private var prunedOverlay: some View {
        if let prunedNotice {
            Text(prunedNotice == 1 ? "1 item removed from your selection"
                                   : "\(prunedNotice) items removed from your selection")
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar, in: Capsule())
                .padding(.top, 8)
                .transition(.opacity)
        }
    }

    private func showPruned(_ n: Int) {
        withAnimation { prunedNotice = n }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { prunedNotice = nil }
        }
    }

    // MARK: Loading

    /// §6.3: check authorisation before fetching, so denied never flashes an empty state.
    private func start() async {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: access = .notAsked
        case .denied, .restricted: access = .denied
        default: await load()
        }
    }

    private func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { access = .denied; return }
        access = status == .limited ? .limited : .full
        photosTask?.cancel()
        let gen = generation.begin()
        let current = { generation.isCurrent(gen) }
        loadingVideos = true
        loadingPhotos = true
        showProgress = false
        progress = LoadProgress()
        let started = Date()
        let delay = Task {
            try? await Task.sleep(for: .seconds(LoadProgress.showDelay))
            if !Task.isCancelled, current(), LoadProgress.shouldShow(elapsed: Date().timeIntervalSince(started)) { showProgress = true }
        }
        // PhotoKit callbacks fire on a background thread; hop to the main actor before touching state.
        // Every write after an await is gated on `current()` so an overlapping reload can't be clobbered.
        let photos = Task {
            let p = await PhotoLibrary.fetchPhotosLargestFirst { scanned, total in
                Task { @MainActor in if current() { progress.photos = (scanned, total) } }
            }
            if current() { allPhotos = p; loadingPhotos = false }
        }
        photosTask = photos
        let v = await PhotoLibrary.fetchVideosLargestFirst { scanned, total in
            Task { @MainActor in if current() { progress.videos = (scanned, total) } }
        }
        if current() { allVideos = v; loadingVideos = false }
        await photos.value
        delay.cancel()
        guard current() else { return }
        showProgress = false
        let ready = SavingsStats.load().readyIDs
        if access == .full, !ready.isEmpty {
            let existing = PhotoLibrary.existingIDs(Array(ready))
            SavingsStats.update { $0.prune(keeping: existing) }
        }
    }

    private func presentLimitedPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root) { _ in
            Task { await load() }
        }
    }

    private func spokenDuration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
