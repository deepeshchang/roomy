import SwiftUI

/// Spec §5.2 / §11.7: carries what the iOS sheet lacks, then hands off to it.
/// Not a second "are you sure".
struct DeleteOriginalsSheet: View {
    let store: BatchStore
    /// Called with whether iOS actually deleted anything.
    let onResult: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var comparing: VideoItem?
    @State private var deleting = false

    private var targets: [VideoItem] { store.items.filter(\.canDeleteOriginal) }

    var body: some View {
        let count = store.deletableCount
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    strip
                    if let first = targets.max(by: { $0.sourceBytes < $1.sourceBytes }) {
                        Button("Compare First") { comparing = first }.font(.footnote)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Frees").foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: store.deletableFreedBytes,
                                                           countStyle: .file))
                                .monospacedDigit().foregroundStyle(.green)
                        }
                        GridRow {
                            Text("Keeps").foregroundStyle(.secondary)
                            Text("\(count) compressed copies, with their original dates, locations and albums")
                                .monospacedDigit()
                        }
                    }
                    Text("They move to Recently Deleted for 30 days. To get the space back right now, empty Recently Deleted in Photos.")
                        .font(.subheadline)
                    if store.excludedFromDeleteCount > 0 {
                        Text("\(store.excludedFromDeleteCount) items aren't included — their originals are kept.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 8) {
                        Button(role: .destructive) {
                            deleting = true
                            Task {
                                let deleted = await store.deleteAllOriginals()
                                onResult(deleted)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if deleting { ProgressView() }
                                Text(deleting ? "Deleting…" : "Delete \(count) Originals")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .disabled(count == 0 || deleting)
                        .accessibilityIdentifier("delete.confirm")
                        Button("Cancel") { dismiss() }.accessibilityIdentifier("delete.cancel")
                    }
                }
                .padding(16)
            }
            .navigationTitle("Delete \(count) originals?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $comparing) { CompareView(item: $0, store: store) }
        }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ForEach(targets.prefix(6)) { item in
                ThumbnailImage(assetID: item.assetID, side: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if targets.count > 6 {
                Text("+\(targets.count - 6)").foregroundStyle(.secondary).monospacedDigit()
                    .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(targets.count) items")
    }
}
