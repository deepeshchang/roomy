import SwiftUI

/// Short, native help. Plain text in a grouped list, one Done (E12 pattern).
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What Roomy does") {
                    Text("Roomy lists your videos and photos largest first. Pick the ones you want smaller, and Roomy makes a compressed copy of each and saves it to Photos.")
                }
                Section("What's kept") {
                    Label("The date and time it was taken", systemImage: "calendar")
                    Label("Where it was taken", systemImage: "location")
                    Label("Its albums and favourites", systemImage: "rectangle.stack")
                    Label("Live Photos stay live", systemImage: "livephoto")
                }
                Section("Your originals") {
                    Text("Originals stay in Photos, untouched, until you choose to delete them. Deleted originals go to Recently Deleted for 30 days, so you can still get them back. The space is freed once that folder is emptied.")
                }
                Section("The settings") {
                    ForEach([VideoPreset.high, .balanced, .maximum]) { preset in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.title)
                            Text(preset.summary).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(VideoPreset.custom.title)
                        Text(VideoPreset.custom.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Photo quality and downscaling")
                        Text("High keeps more fine detail. Downscaling only touches photos bigger than an iPhone's own 12 MP.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Privacy") {
                    Label("Everything happens on this iPhone. Nothing is uploaded.", systemImage: "iphone")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("help.done") }
            }
        }
    }
}
