import Testing
import Foundation
import CoreGraphics
@testable import VideoCompressor

@MainActor @Test func probesARealFileAccurately() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }

    let m = try await VideoProbe.probe(url: url)

    #expect(m.width == 320)
    #expect(m.height == 240)
    #expect(m.isH264, "fixture is written as H.264, got \(m.codec)")
    #expect(!m.isHEVC)
    #expect(m.fileSize > 0)
    #expect(m.duration > 0.5 && m.duration < 2.0)
    #expect(m.frameRate > 25 && m.frameRate < 35)
    #expect(m.filename == url.lastPathComponent)
}

@MainActor @Test func reportsBitrateForARealFile() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }

    let m = try await VideoProbe.probe(url: url)
    #expect(m.bitrate > 0)
}

@MainActor @Test func throwsOnAFileWithNoVideoTrack() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-a-video-\(UUID().uuidString).mov")
    try Data("this is not a movie".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: (any Error).self) {
        _ = try await VideoProbe.probe(url: url)
    }
}
