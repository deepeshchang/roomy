import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import VideoCompressor

@MainActor @Test func compressesToHEVCAndProducesAPlayableFile() async throws {
    let source = try await FixtureVideo.make(seconds: 2, size: CGSize(width: 640, height: 480))
    defer { try? FileManager.default.removeItem(at: source) }

    let output = try await compress(source, target: .mb200)
    defer { try? FileManager.default.removeItem(at: output) }

    #expect(FileManager.default.fileExists(atPath: output.path))

    let result = try await VideoProbe.probe(url: output)
    #expect(result.isHEVC, "output must be HEVC, got \(result.codec)")
    #expect(result.duration > 1.5 && result.duration < 2.5)
}

@MainActor @Test func leavesTheSourceFileUntouched() async throws {
    let source = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: source) }

    let before = try await VideoProbe.probe(url: source)

    let output = try await compress(source, target: .mb200)
    defer { try? FileManager.default.removeItem(at: output) }

    let after = try await VideoProbe.probe(url: source)
    #expect(before == after, "compressing must never modify the source")
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@MainActor @Test func reportsMonotonicProgressEndingAtOne() async throws {
    let source = try await FixtureVideo.make(seconds: 4, size: CGSize(width: 1280, height: 720))
    defer { try? FileManager.default.removeItem(at: source) }

    // The callback is @Sendable and fires off-actor, so collect under a lock.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let box = Box()

    let output = try await compress(source, target: .mb200) { box.append($0) }
    defer { try? FileManager.default.removeItem(at: output) }

    let values = box.all
    #expect(!values.isEmpty, "progress must be reported at least once")
    #expect(values == values.sorted(), "progress must never go backwards")
    #expect(values.last == 1.0, "progress must finish at 1.0")
    #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
}

@MainActor @Test func writesEachOutputToADistinctURL() async throws {
    let source = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: source) }

    let a = try await compress(source, target: .mb200)
    let b = try await compress(source, target: .mb200)
    defer {
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
    }

    #expect(a != b, "concurrent batch items must not collide on one path")
}

@MainActor @Test func throwsOnANonVideoFile() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("junk-\(UUID().uuidString).mov")
    try Data("not a movie".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: (any Error).self) {
        _ = try await compress(url, target: .mb200)
    }
}

// MARK: - Helpers

/// Transcode a file with a plan derived from its own metadata, the way
/// BatchStore does.
@MainActor
private func compress(_ source: URL, target: TargetSize,
                      onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
    let metadata = (try? await VideoProbe.probe(url: source))
        ?? VideoMetadata(filename: source.lastPathComponent, fileSize: 0, duration: 1,
                         width: 640, height: 480, frameRate: 30, codec: "", bitrate: 0)
    return try await VideoCompressorEngine().compress(
        asset: AVAssetBox(asset: AVURLAsset(url: source)),
        basename: source.deletingPathExtension().lastPathComponent,
        plan: CompressionPlan.plan(for: metadata, target: target),
        onProgress: onProgress)
}

@MainActor
@Test func honoursTheRequestedResolutionAndShrinksTheFile() async throws {
    // 720p source, tight target: the plan should downscale and the output must
    // actually come out at the planned size, not the source size.
    let source = try await FixtureVideo.make(seconds: 3, size: CGSize(width: 1280, height: 720))
    defer { try? FileManager.default.removeItem(at: source) }

    var metadata = try await VideoProbe.probe(url: source)
    metadata = VideoMetadata(filename: metadata.filename, fileSize: metadata.fileSize,
                             duration: 3600,   // pretend it is an hour long
                             width: 1280, height: 720, frameRate: 30,
                             codec: "h264", bitrate: 0)
    let plan = CompressionPlan.plan(for: metadata, target: .mb50)
    #expect(max(plan.width, plan.height) < 1280, "an hour into 50 MB must downscale")

    let output = try await VideoCompressorEngine().compress(
        asset: AVAssetBox(asset: AVURLAsset(url: source)),
        basename: "scaled", plan: plan) { _ in }
    defer { try? FileManager.default.removeItem(at: output) }

    let result = try await VideoProbe.probe(url: output)
    #expect(result.width == plan.width, "expected \(plan.width), got \(result.width)")
    #expect(result.height == plan.height, "expected \(plan.height), got \(result.height)")
    #expect(result.isHEVC)
}

@MainActor
@Test func portraitVideoStaysPortrait() async throws {
    // The classic transcoder bug: portrait clips come out sideways or squashed.
    let source = try await FixtureVideo.make(seconds: 2, size: CGSize(width: 480, height: 854))
    defer { try? FileManager.default.removeItem(at: source) }

    let output = try await compress(source, target: .mb200)
    defer { try? FileManager.default.removeItem(at: output) }

    let result = try await VideoProbe.probe(url: output)
    #expect(result.height > result.width,
            "portrait source became \(result.width)x\(result.height)")
}

@MainActor
@Test func audioSurvivesTheReEncode() async throws {
    let source = try await FixtureVideo.makeWithAudio(seconds: 2)
    defer { try? FileManager.default.removeItem(at: source) }

    let output = try await compress(source, target: .mb200)
    defer { try? FileManager.default.removeItem(at: output) }

    let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
    #expect(!tracks.isEmpty, "the audio track must not be dropped")
}

@MainActor
@Test func aLongVideoWithAudioDoesNotDeadlock() async throws {
    // Regression: video was pumped to completion before audio, and
    // AVAssetWriter's interleaving stalled video waiting for audio forever.
    // 2 s clips fit in the writer's buffer and hid it; this one must not.
    let source = try await FixtureVideo.makeWithAudio(seconds: 20)
    defer { try? FileManager.default.removeItem(at: source) }

    let output = try await compress(source, target: .mb200)
    defer { try? FileManager.default.removeItem(at: output) }

    let result = try await VideoProbe.probe(url: output)
    #expect(result.duration > 19 && result.duration < 21)
    let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
    #expect(!audio.isEmpty)
}

@MainActor
@Test func cancellingStopsTheExportAndLeavesNoFile() async throws {
    let source = try await FixtureVideo.makeWithAudio(seconds: 20)
    defer { try? FileManager.default.removeItem(at: source) }

    // Other tests write to the same directory in parallel, so only this
    // source's own outputs count.
    let prefix = source.deletingPathExtension().lastPathComponent + "-hevc-"
    func mine() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: VideoCompressorEngine.workingDirectory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
    }

    let task = Task { try await compress(source, target: .mb200) }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    await #expect(throws: CompressionError.self) { _ = try await task.value }

    #expect(mine().isEmpty, "a cancelled export must not leave a partial file: \(mine())")
}
