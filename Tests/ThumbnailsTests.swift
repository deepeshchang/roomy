import Testing
import CoreGraphics
import Foundation
@testable import VideoCompressor

@MainActor @Test func missingAssetIDYieldsNilRatherThanHanging() async throws {
    let image = await Thumbnails.image(for: "not-a-real-local-identifier/L0/001", size: 120)
    #expect(image == nil)
}

@MainActor @Test func fileURLYieldsAFirstFrameThumbnail() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try #require(await Thumbnails.image(for: url, size: 120))
    #expect(image.size.width > 0 && image.size.height > 0)
}

@MainActor @Test func unreadableFileURLYieldsNil() async throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-\(UUID().uuidString).mov")
    #expect(await Thumbnails.image(for: missing, size: 120) == nil)
}

/// Caching is advisory: unknown IDs must be a no-op, not a crash, because the
/// grid calls stopCaching for rows whose asset was deleted mid-scroll.
@MainActor @Test func cachingUnknownIDsIsHarmless() {
    Thumbnails.startCaching(assetIDs: ["bogus-1", "bogus-2"], size: 120)
    Thumbnails.stopCaching(assetIDs: ["bogus-1", "bogus-2"], size: 120)
}
