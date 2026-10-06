import Testing
import Foundation
import CoreGraphics
@testable import VideoCompressor

// QA B1: a file must never come back bigger, and a bigger copy must never be saved.

private func clip(sizeMB: Double, seconds: Double = 60, bitrate: Double = 0) -> VideoMetadata {
    VideoMetadata(filename: "c.mov", fileSize: Int64(sizeMB * 1_000_000), duration: seconds,
                  width: 1920, height: 1080, frameRate: 30, codec: "hvc1", bitrate: bitrate)
}

@Test func planNeverSpendsMoreThanSixtyPercentOfTheSource() {
    let m = clip(sizeMB: 20)   // ~2.7 Mbps, far under a 200 MB budget
    let plan = CompressionPlan.plan(for: m, target: .mb200)
    #expect(Double(plan.estimatedBytes) <= Double(m.fileSize) * 0.61,
            "planned \(plan.estimatedBytes) for a \(m.fileSize) source")
}

@Test func planUsesTheProbedBitrateWhenKnown() {
    let m = clip(sizeMB: 200, bitrate: 1_000_000)   // probe says 1 Mbps
    let plan = CompressionPlan.plan(for: m, target: .mb500)
    #expect(Double(plan.videoBitrate + plan.audioBitrate) <= 600_001)
}

@Test(arguments: [VideoPreset.high, .balanced, .maximum, .custom])
func presetsAreCeilingsNotGoals(_ preset: VideoPreset) {
    let m = clip(sizeMB: 15)
    let plan = CompressionSettings(videoPreset: preset).videoPlan(for: m)
    #expect(Double(plan.estimatedBytes) <= Double(m.fileSize) * 0.61)
}

@Test func photoAlreadyAtTheRatioIsNotWorthIt() {
    // A small HEIC re-encode never claims more than it can save.
    let p = LibraryPhoto(id: "p", filename: "p.heic", fileSize: 400_000, width: 1000, height: 1000,
                         creationDate: nil, uti: "public.heic", isLivePhoto: false)
    #expect(CompressionSettings().photoPlan(for: p).estimatedBytes < p.fileSize)
}

@MainActor
@Test func aLowBitrateVideoIsAlreadySmallNotQueued() {
    let v = LibraryVideo(id: "v", filename: "v.mov", fileSize: 1_000_000, duration: 60,
                         creationDate: nil, width: 1920, height: 1080)
    let store = BatchStore()
    store.enqueue(videos: [v], photos: [])
    #expect(store.items.first?.state == .alreadySmall)
    #expect(!store.hasWork, "Start must be disabled when nothing would shrink")
    #expect(store.phase == .review)
}

@MainActor
@Test func enqueuedItemsExistImmediatelyAndAreInReview() {
    let v = LibraryVideo(id: "v", filename: "v.mov", fileSize: 2_000_000_000, duration: 600,
                         creationDate: nil, width: 1920, height: 1080)
    let store = BatchStore()
    store.enqueue(videos: [v], photos: [])
    #expect(store.items.map(\.state) == [.ready])
    #expect(store.phase == .review)
}

@MainActor
@Test func anOutputThatIsNotSmallerIsDiscardedAndNeverDeletable() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }
    let store = BatchStore()
    await store.add(urls: [url])
    let item = try #require(store.items.first)
    // Pretend the source was tiny: any real encode is then "bigger".
    item.metadata = VideoMetadata(filename: "f.mov", fileSize: 10, duration: 1, width: 320,
                                  height: 240, frameRate: 30, codec: "avc1", bitrate: 0)
    item.estimate = nil
    item.state = .ready
    await store.compressAll()

    #expect(item.state == .alreadySmall)
    #expect(item.outputURL == nil)
    #expect(!item.savedToPhotos)
    #expect(!item.canDeleteOriginal)
    #expect(store.deletableCount == 0)
}

@MainActor
@Test func cancellingBeforeAnythingFinishesIsStoppedNotReview() {
    let store = BatchStore()
    let i = VideoItem(sourceURL: nil, assetID: "a"); i.state = .ready
    store.items = [i]
    store.hasStarted = true   // what startBatch/compressAll record
    #expect(store.phase == .stopped)
    store.clear()
    #expect(store.phase == .review)
}

@MainActor
@Test func compressAllRecordsThatTheBatchStarted() async {
    let store = BatchStore()
    let broken = VideoItem(sourceURL: nil, assetID: "p", kind: .photo)   // fails at once
    broken.state = .ready
    store.items = [broken]
    await store.compressAll()
    #expect(store.hasStarted)
    #expect(store.phase == .done)
}

@MainActor
@Test func itemsAddedMidBatchAreCompressedToo() async {
    let store = BatchStore()
    let first = VideoItem(sourceURL: nil, assetID: "1", kind: .photo); first.state = .ready
    let late = VideoItem(sourceURL: nil, assetID: "2", kind: .photo); late.state = .ready
    store.items = [first]
    var added = false
    await store.compressAll { _, _ in
        if !added { added = true; store.items.append(late) }
    }
    #expect(late.state != .ready, "the late item must be picked up, got \(late.state)")
}

@MainActor
@Test func doneReturnsUnstartedItemsToTheSelection() {
    let store = BatchStore()
    let a = VideoItem(sourceURL: nil, assetID: "a"); a.state = .finished
    let b = VideoItem(sourceURL: nil, assetID: "b"); b.state = .ready
    let c = VideoItem(sourceURL: nil, assetID: "c"); c.state = .alreadySmall
    store.items = [a, b, c]
    store.selection = LibrarySelection(ids: ["a", "b", "c", "x"])
    store.finishBatch()
    #expect(store.selection.ids == ["b", "x"])
    #expect(store.items.isEmpty)
    #expect(store.libraryGeneration == 1, "the library is told to refresh")
}

@MainActor
@Test func alreadySmallAndStartedSurviveARelaunch() {
    let store = BatchStore()
    let c = VideoItem(sourceURL: nil, assetID: "c"); c.state = .alreadySmall
    store.items = [c]
    store.hasStarted = true
    let next = BatchStore()
    next.restore(store.snapshot)
    #expect(next.items[0].state == .alreadySmall)
    #expect(next.hasStarted)
}
