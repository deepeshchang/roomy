import SwiftUI

/// One screen, states Review → Running ⇄ Stopped → Done, all derived from the
/// store (spec §4, §11.4, §14). Returning from the background needs no reload.
struct BatchView: View {
    let store: BatchStore
    let onShowSettings: () -> Void
    let onClose: () -> Void

    @State private var confirmCancel = false
    @State private var showDelete = false
    @State private var comparing: VideoItem?
    @State private var failure: VideoItem?
    @State private var note: String?

    private var phase: BatchStore.Phase { store.phase }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header.padding(.horizontal, 16)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("batch.header")
                Text(phase.name).hidden().frame(height: 0)
                    .accessibilityIdentifier("batch.phase").accessibilityLabel(phase.name)
                grid
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemBackground))
        .navigationTitle(phase == .review ? "Review" : "Batch")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(phase == .review || phase == .running)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if phase == .review {
                    Button("Cancel", action: onClose)   // E3: selection kept in Library
                } else if phase == .running {
                    Button("Cancel Batch") { confirmCancel = true }
                        .accessibilityIdentifier("batch.cancelBatch")
                        .confirmationDialog("Cancel this batch?", isPresented: $confirmCancel,
                                            titleVisibility: .visible) {
                            Button("Cancel Batch", role: .destructive) { store.cancelBatch() }
                                .accessibilityIdentifier("batch.confirmCancel")
                            Button("Keep Compressing", role: .cancel) {}
                        } message: {
                            Text("\(store.finishedCount) finished items are saved in Photos. The item in progress is discarded and \(max(0, store.remainingCount - 1)) items won't be compressed.")
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showDelete) {
            DeleteOriginalsSheet(store: store) { deleted in
                note = deleted
                    ? "\(bytes(store.totalSavedBytes)) will be free once you empty Recently Deleted."
                    : "Nothing was deleted. Your originals are still in Photos."
            }
        }
        .sheet(item: $comparing) { CompareView(item: $0, store: store) }
        .sheet(item: $failure) { item in failureSheet(item) }
        .task(id: note) {
            // E10: the "nothing deleted" footnote auto-hides; the freed banner stays.
            guard let note, note.hasPrefix("Nothing") else { return }
            try? await Task.sleep(for: .seconds(4))
            if self.note == note { self.note = nil }
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch phase {
        case .review:
            VStack(alignment: .leading, spacing: 12) {
                Text("\(store.items.count) items · \(bytes(sourceTotal)) · ≈ \(bytes(estimatedTotal)) to free")
                    .font(.headline).monospacedDigit()
                Button(action: onShowSettings) {
                    HStack {
                        Text("Video quality").foregroundStyle(.primary)
                        Spacer()
                        Text(store.settings.videoPreset == .custom
                             ? store.target.displayName : store.settings.videoPreset.title)
                            .monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !store.hasWork && !store.items.isEmpty {
                    Text("Nothing here would get smaller — these are already compressed efficiently. Try other items or a different setting.")
                        .font(.footnote).foregroundStyle(.orange)
                } else if store.alreadySmallCount > 0 {
                    Text("\(store.alreadySmallCount) already small, so they'll be left as they are.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Originals stay untouched until you delete them.")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.canUndoRemove {
                    HStack {
                        Text("Removed from batch").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") { withAnimation { store.undoRemove() } }
                            .font(.footnote.bold())
                            .accessibilityIdentifier("batch.undoRemove")
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                Text("Compressing \(min(store.finishedCount + 1, store.items.count)) of \(store.items.count)")
                    .font(.headline).monospacedDigit()
                    .contentTransition(.numericText())
                ProgressView(value: Double(store.finishedCount) + currentFraction,
                             total: Double(max(1, store.items.count)))
                    .progressViewStyle(.linear)
                if let currentStep {
                    Text(currentStep).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                }
                if let remaining = store.timeRemainingText {
                    Text(remaining).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("batch.timeRemaining")
                }
                freedLine
                failurePill
            }
        case .stopped:
            VStack(alignment: .leading, spacing: 8) {
                Text("Stopped — \(store.finishedCount) of \(store.items.count) done · \(bytes(store.totalSavedBytes)) freed")
                    .font(.headline).monospacedDigit()
                Text("The \(store.remainingCount) not started are still in this batch.")
                    .font(.subheadline).foregroundStyle(.secondary)
                failurePill
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .done:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Freed \(bytes(store.totalSavedBytes))")
                    .font(.largeTitle.bold()).monospacedDigit()
                    .contentTransition(.numericText())
                Text(store.alreadySmallCount > 0
                     ? "\(store.finishedCount) compressed · \(store.alreadySmallCount) already small · \(store.skippedCount) skipped"
                     : "\(store.finishedCount) compressed · \(store.skippedCount) skipped")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                failurePill
                if let largest {
                    Button("Compare Before and After") { comparing = largest }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var freedLine: some View {
        Text(store.totalSavedBytes > 0 ? "\(bytes(store.totalSavedBytes)) freed so far" : "Nothing freed yet")
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            .contentTransition(.numericText())
    }

    @ViewBuilder private var failurePill: some View {
        if store.skippedCount > 0 {
            HStack(spacing: 12) {
                Text("\(store.skippedCount) couldn't be compressed")
                    .font(.footnote).foregroundStyle(.orange)
                if phase != .running {
                    Button("Retry") { withAnimation { store.retryAllFailed() } }
                        .font(.footnote.bold())
                        .accessibilityIdentifier("batch.retryFailed")
                }
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
            ForEach(store.items) { item in
                BatchCell(item: item, phase: phase)
                    .onTapGesture { tap(item) }
                    .contextMenu {
                        if phase == .review {
                            Button("Remove from Batch", systemImage: "minus.circle") { store.remove(item) }
                        } else if item.canDeleteOriginal {
                            Button("Delete Original", systemImage: "trash", role: .destructive) {
                                Task {
                                    let deleted = (try? await store.deleteOriginal(item)) ?? false
                                    if !deleted { note = "Nothing was deleted. Your originals are still in Photos." }
                                }
                            }
                        }
                    }
            }
        }
    }

    private func tap(_ item: VideoItem) {
        switch item.state {
        case .finished: comparing = item
        case .failed: failure = item
        case .ready where phase == .review, .alreadySmall where phase == .review: store.remove(item)
        default: break
        }
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        switch phase {
        case .running:
            EmptyView()
        case .review:
            bar {
                Button { store.startBatch() } label: {
                    // The background-coloured label vanished on a disabled
                    // button, leaving an empty grey box; fall back to secondary.
                    Text("Start").frame(maxWidth: .infinity)
                        .foregroundStyle(store.hasWork ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!store.hasWork)
                .accessibilityIdentifier("batch.start")
            }
        case .stopped:
            bar {
                HStack {
                    Button { store.startBatch() } label: {
                        Text("Resume").frame(maxWidth: .infinity).foregroundStyle(.background)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("batch.resume")
                    Button(action: finish) { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("batch.done")
                }
                deleteButton
            }
        case .done:
            bar {
                // Done is the primary way out; deleting is the quieter
                // secondary choice under it, never the loudest thing (QA).
                Button(action: finish) {
                    Text("Done").frame(maxWidth: .infinity).foregroundStyle(.background)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("batch.done")
                deleteButton
            }
        }
    }

    @ViewBuilder private var deleteButton: some View {
        if store.deletableCount > 0 {
            Button(role: .destructive) { showDelete = true } label: {
                Text("Delete \(store.deletableCount) Originals…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("batch.deleteOriginals")
        }
        if let note {
            HStack {
                Text(note).font(.footnote).foregroundStyle(.secondary)
                if !note.hasPrefix("Nothing"), let url = URL(string: "photos-redirect://") {
                    Spacer()
                    Button("Open Photos") { UIApplication.shared.open(url) }.font(.footnote)
                }
            }
        }
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 8, content: content)
            .padding(16)
            .background(.bar)
    }

    /// E7/E8: pop; unstarted items go back to the Library selection.
    private func finish() {
        onClose()
        store.finishBatch()
    }

    private func failureSheet(_ item: VideoItem) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                ThumbnailImage(assetID: item.assetID, fileURL: item.sourceURL, side: 120)
                if case .failed(let reason) = item.state {
                    Text(reason).multilineTextAlignment(.center)
                }
                Text("Your original is untouched.").font(.footnote).foregroundStyle(.secondary)
                if phase != .running {
                    Button {
                        store.retry(item); failure = nil
                    } label: {
                        Text("Retry").frame(maxWidth: .infinity).foregroundStyle(.background)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("failure.retry")
                }
            }
            .padding(16)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { failure = nil } }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Numbers

    private var currentFraction: Double {
        for item in store.items {
            if item.state == .compressing { return item.progress }
            if case .downloading = item.state { return 0 }
        }
        return 0
    }

    /// What the item in flight is doing right now, in words.
    private var currentStep: String? {
        for item in store.items {
            switch item.state {
            case .downloading(let f): return "Downloading \(itemNoun(item)) from iCloud · \(Int(f * 100))%"
            case .compressing: return "Compressing \(itemNoun(item)) · \(Int(item.progress * 100))%"
            case .finished where !item.savedToPhotos: return "Saving \(itemNoun(item)) to Photos…"
            default: continue
            }
        }
        return nil
    }

    private var sourceTotal: Int64 { store.items.reduce(0) { $0 + $1.sourceBytes } }
    private var estimatedTotal: Int64 { store.items.reduce(0) { $0 + ($1.estimate?.savedBytes ?? 0) } }
    private var largest: VideoItem? {
        store.items.filter { $0.state == .finished }.max { $0.sourceBytes < $1.sourceBytes }
    }
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

/// One grid cell. Run state replaces the selection control (§4.2).
private struct BatchCell: View {
    let item: VideoItem
    let phase: BatchStore.Phase

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ThumbnailImage(assetID: item.assetID, fileURL: item.sourceURL, side: geo.size.width)
                }
            }
            .clipped()
            .opacity((item.state == .ready && phase != .review) || item.state == .alreadySmall ? 0.5 : 1)
            .overlay {
                if case .failed = item.state { Color.orange.opacity(0.12) }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 36)
            }
            .overlay(alignment: .bottomTrailing) { label.padding(4) }
            .overlay { if isSaving { ProgressView().tint(.white) } }
            .overlay(alignment: .topTrailing) { badge.padding(4) }
            .overlay(alignment: .bottom) { bar }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("batch.cell.\(item.assetID ?? item.id.uuidString)")
    }

    @ViewBuilder private var label: some View {
        Group {
            switch item.state {
            case .finished where isSaving:
                Text("Saving").foregroundStyle(.white)
            case .finished:
                Text("−\(bytes(item.actualSavedBytes))").foregroundStyle(.green)
                    .contentTransition(.numericText())
            case .compressing:
                Text("\(Int(item.progress * 100))%").foregroundStyle(.white)
            case .alreadySmall:
                Text("Already small").foregroundStyle(.white)
            case .downloading(let f):
                Text("iCloud \(Int(f * 100))%").foregroundStyle(.white)
            default:
                Text(bytes(item.sourceBytes)).foregroundStyle(.white)
            }
        }
        .font(.caption2.bold()).monospacedDigit()
        // Keeps the label legible on very bright thumbnails.
        .shadow(color: .black.opacity(0.8), radius: 1.5, y: 0.5)
    }

    @ViewBuilder private var badge: some View {
        Group {
            switch item.state {
            case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .downloading: Image(systemName: "icloud.and.arrow.down").foregroundStyle(.white)
            case .ready where phase == .review:
                Image(systemName: "minus.circle.fill").foregroundStyle(.white, .black.opacity(0.4))
            default: EmptyView()
            }
        }
        .imageScale(.large)
    }

    @ViewBuilder private var bar: some View {
        switch item.state {
        case .compressing: ProgressView(value: item.progress).progressViewStyle(.linear)
        case .downloading(let f): ProgressView(value: f).progressViewStyle(.linear)
        default: EmptyView()
        }
    }

    /// Compressed, not yet in Photos — only while the batch is running.
    private var isSaving: Bool { phase == .running && item.state == .finished && !item.savedToPhotos }

    private var accessibilityText: String {
        let kind = item.kind == .photo ? "Photo" : "Video"
        if isSaving { return "\(kind), saving to Photos" }
        switch item.state {
        case .finished: return "\(kind), saved \(bytes(item.actualSavedBytes))"
        case .alreadySmall: return "\(kind), already small, left as it is"
        case .failed(let why): return "\(kind), couldn't be compressed. \(why)"
        case .compressing: return "\(kind), compressing, \(Int(item.progress * 100)) percent"
        default: return "\(kind), \(bytes(item.sourceBytes))"
        }
    }
}

/// Library filenames are often meaningless (WhatsApp and iCloud use long
/// generated names), so progress text names the item by what it is.
@MainActor
private func itemNoun(_ item: VideoItem) -> String {
    item.kind == .photo ? "photo" : "video"
}
