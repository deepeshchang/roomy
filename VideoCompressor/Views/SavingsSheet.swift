import SwiftUI

/// Details behind the library's savings card (library-v2 spec §2.1).
struct SavingsSheet: View {
    let stats: SavingsStats
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Saved", value: bytes(stats.savedBytes))
                    LabeledContent("Videos", value: stats.videoCount.formatted())
                    LabeledContent("Photos", value: stats.photoCount.formatted())
                    if let date = stats.lastBatchDate {
                        LabeledContent("Last batch",
                                       value: "\(bytes(stats.lastBatchBytes)), \(date.formatted(.dateTime.day().month()))")
                    }
                } footer: {
                    if stats.readyBytes == 0 { footer }
                }
                .monospacedDigit()

                if stats.readyBytes > 0 {
                    Section {
                        LabeledContent("Ready to free", value: bytes(stats.readyBytes))
                            .monospacedDigit()
                        Button(role: .destructive) {
                            deleting = true
                            Task {
                                // iOS shows its own confirmation; only a confirmed
                                // delete moves these into "Saved".
                                // Re-check every copy right now: only originals
                                // whose copy still exists are ever deleted.
                                let current = SavingsStats.load()
                                let copies = current.ready.mapValues(\.copyID)
                                let plan = SavingsStats.deletionPlan(
                                    copies: copies,
                                    existing: PhotoLibrary.existingIDs(copies.values.compactMap { $0 }))
                                SavingsStats.update { $0.drop(ids: plan.drop) }
                                let ids = plan.safe
                                if !ids.isEmpty, await PhotoLibrary.deleteOriginals(ids: ids) {
                                    SavingsStats.update { $0.recordDeleted(ids: ids) }
                                }
                                deleting = false
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(deleting ? "Deleting…" : "Delete Originals…")
                                if deleting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(deleting)
                        .accessibilityIdentifier("savings.deleteOriginals")
                    } footer: {
                        footer
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Savings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: some View {
        Text("Only originals you deleted through Roomy count as saved. Deleted originals stay in Recently Deleted for 30 days. Space returns once that's emptied, in Photos → Albums → Recently Deleted. Totals are kept on this iPhone and reset if you delete Roomy.")
    }
}
