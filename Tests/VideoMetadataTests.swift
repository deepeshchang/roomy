import Testing
import Foundation
import CoreGraphics
@testable import VideoCompressor

private func sample(codec: String = "h264",
                    width: Int = 1920,
                    height: Int = 1080,
                    fileSize: Int64 = 200_000_000,
                    duration: Double = 61) -> VideoMetadata {
    VideoMetadata(filename: "IMG_0001.MOV",
                  fileSize: fileSize,
                  duration: duration,
                  width: width,
                  height: height,
                  frameRate: 30,
                  codec: codec,
                  bitrate: 26_000_000)
}

@Test func detectsHEVC() {
    #expect(sample(codec: "hvc1").isHEVC)
    #expect(sample(codec: "hev1").isHEVC)
    #expect(!sample(codec: "h264").isHEVC)
}

@Test func detectsH264() {
    #expect(sample(codec: "h264").isH264)
    #expect(sample(codec: "avc1").isH264)
    #expect(!sample(codec: "hvc1").isH264)
}

@Test func codecDetectionIgnoresCase() {
    #expect(sample(codec: "HVC1").isHEVC)
    #expect(sample(codec: "AVC1").isH264)
}

@Test func buildsResolutionLabel() {
    #expect(sample(width: 1920, height: 1080).resolutionLabel == "1920×1080")
}

@Test func formatsDurationAsMinutesAndSeconds() {
    #expect(sample(duration: 61).formattedDuration == "1:01")
    #expect(sample(duration: 9).formattedDuration == "0:09")
    #expect(sample(duration: 600).formattedDuration == "10:00")
}

@Test func formatsSizeHumanReadably() {
    let text = sample(fileSize: 200_000_000).formattedSize
    #expect(text.contains("MB"))
}

@Test func fixtureGeneratorProducesAPlayableFile() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }

    let size = try FileManager.default
        .attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
    #expect(size > 0)
    #expect(url.pathExtension == "mov")
}
