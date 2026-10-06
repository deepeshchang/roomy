import SwiftUI

/// Compression settings in plain words. Applies on tap; no Apply, no Cancel (§12, E12).
struct SettingsView: View {
    @Binding var videoPreset: VideoPreset
    @Binding var target: TargetSize
    @Binding var photoQuality: PhotoQuality
    @Binding var downscaleLargePhotos: Bool
    var isRunning = false
    /// How many items the estimate covers (the unstarted batch, or the selection).
    var estimateCount = 0
    /// Bytes freed for those items under the given settings.
    var estimate: (CompressionSettings) -> Int64 = { _ in 0 }
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    private var settings: CompressionSettings {
        CompressionSettings(videoPreset: videoPreset, target: target,
                            photoQuality: photoQuality, downscaleLargePhotos: downscaleLargePhotos)
    }

    var body: some View {
        NavigationStack {
            List {
                if estimateCount > 0 {
                    Section {
                        LabeledContent("\(estimateCount) items", value: "≈ \(bytes(estimate(settings))) freed")
                            .monospacedDigit()
                            .foregroundStyle(.green)
                            .contentTransition(.numericText())
                            .animation(.default, value: settings)
                    } footer: {
                        Text(isRunning ? "Changes apply to items not started yet."
                                       : "Updates as you change the settings below.")
                    }
                }

                Section {
                    ForEach(VideoPreset.allCases) { preset in
                        Button { videoPreset = preset } label: { row(preset) }
                            .tint(.primary)
                            .accessibilityAddTraits(preset == videoPreset ? .isSelected : [])
                    }
                    if videoPreset == .custom {
                        Picker("Size per video", selection: $target) {
                            ForEach(TargetSize.allCases) { Text($0.displayName).tag($0) }
                        }
                        .monospacedDigit()
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text("Videos bigger than 1080p are scaled to 1080p. Slow motion is kept.")
                }

                Section {
                    Picker("Quality", selection: $photoQuality) {
                        ForEach(PhotoQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Downscale very large photos", isOn: $downscaleLargePhotos)
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Photos are saved as HEIC. High keeps more fine detail and saves less. Downscaling brings anything bigger than an iPhone photo (12 MP) down to that size; off keeps every pixel.")
                }

                Section {
                    Button("Reset Stats", role: .destructive) { confirmReset = true }
                        .accessibilityIdentifier("settings.resetStats")
                } footer: {
                    Text("Sets \"Roomy has saved you\" back to zero. Nothing in Photos changes.")
                }
                .confirmationDialog("Reset your savings stats?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset Stats", role: .destructive) { SavingsStats.reset() }
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                } header: {
                    Text("About")
                } footer: {
                    Text("Roomy works entirely on this iPhone. Nothing is uploaded. Originals stay in Photos until you delete them, and deleted originals stay in Recently Deleted for 30 days.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
        }
    }

    private func row(_ preset: VideoPreset) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.title)
                Text(preset.summary).font(.footnote).foregroundStyle(.secondary)
                if preset != .custom {
                    Text("A 10-minute video ≈ \(bytes(preset.tenMinuteExampleBytes))")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Image(systemName: "checkmark")
                .foregroundStyle(Color.accentColor)
                .opacity(preset == videoPreset ? 1 : 0)
        }
        .contentShape(Rectangle())
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
