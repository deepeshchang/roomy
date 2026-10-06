import Testing
import Foundation
@testable import VideoCompressor

// Security audit: an original is only ever deleted while its compressed copy
// provably exists in Photos.

@Test func oldSavingsJSONWithoutCopyIDsStillDecodes() throws {
    let old = #"{"savedBytes":5,"videoCount":1,"photoCount":0,"lastBatchBytes":5,"ready":{"a":{"kind":"video","bytes":10}}}"#
    let s = SavingsStats.decode(Data(old.utf8))
    #expect(s.savedBytes == 5)
    #expect(s.ready["a"]?.bytes == 10)
    #expect(s.ready["a"]?.copyID == nil)
}

@Test func onlyOriginalsWhoseCopyStillExistsAreSafeToDelete() {
    let plan = SavingsStats.deletionPlan(
        copies: ["a": "copy-a", "b": "copy-b", "c": nil],
        existing: ["copy-a"])
    #expect(plan.safe == ["a"])
    #expect(plan.drop == ["b", "c"], "a gone copy or no copy ID is never deletable")
}

@Test func droppingRemovesReadyEntriesWithoutCountingThem() {
    var s = SavingsStats()
    s.recordCompressed(id: "a", kind: .video, savedBytes: 10, copyID: "copy-a")
    s.recordCompressed(id: "b", kind: .video, savedBytes: 20, copyID: "copy-b")
    s.drop(ids: ["b"])
    #expect(s.readyIDs == ["a"])
    #expect(s.savedBytes == 0)
}

@Test func aCompressedItemWithoutACopyIDIsNotReady() {
    var s = SavingsStats()
    s.recordCompressed(id: "a", kind: .video, savedBytes: 10, copyID: nil)
    #expect(s.ready.isEmpty)
}

@MainActor
@Test func anItemSavedWithoutACopyIDIsNeverDeletable() {
    let item = VideoItem(sourceURL: nil, assetID: "a")
    item.savedToPhotos = true
    item.savedAssetID = nil
    #expect(!item.canDeleteOriginal)
}

@MainActor
@Test func deleteOriginalRefusesWhenTheCopyIsGone() async throws {
    let store = BatchStore()
    store.copyExists = { _ in [] }
    let item = VideoItem(sourceURL: nil, assetID: "a")
    item.savedToPhotos = true
    item.savedAssetID = "copy-a"
    #expect(try await store.deleteOriginal(item) == false)
    #expect(!item.originalDeleted)
    #expect(!item.canDeleteOriginal, "a vanished copy closes the gate for good")
}

@MainActor
@Test func deleteAllOriginalsSkipsItemsWhoseCopyIsGone() async {
    let store = BatchStore()
    store.copyExists = { _ in [] }
    let item = VideoItem(sourceURL: nil, assetID: "a")
    item.savedToPhotos = true
    item.savedAssetID = "copy-a"
    store.items = [item]
    #expect(await store.deleteAllOriginals() == false)
    #expect(!item.originalDeleted)
    #expect(store.deletableCount == 0)
}

@MainActor
@Test func anUnknownSizeIsNotProvenSmallerSoTheCopyIsDiscarded() {
    let store = BatchStore()
    let unknownSource = VideoItem(sourceURL: nil, assetID: "a")   // sourceBytes 0
    unknownSource.state = .finished
    unknownSource.outputSize = 100
    #expect(store.discardIfNotSmaller(unknownSource))
    #expect(unknownSource.state == .alreadySmall)

    let unknownOutput = VideoItem(sourceURL: nil, assetID: "b")
    unknownOutput.metadata = VideoMetadata(filename: "v.mov", fileSize: 1_000, duration: 1,
                                           width: 1, height: 1, frameRate: 30, codec: "", bitrate: 0)
    unknownOutput.state = .finished
    unknownOutput.outputSize = nil
    #expect(store.discardIfNotSmaller(unknownOutput))
    #expect(!unknownOutput.canDeleteOriginal)
}

@Test func zeroOrGarbageResourceSizesAreUnmeasured() {
    #expect(PhotoLibrary.fileSize(fromKVC: Int64(0)) == nil)
    #expect(PhotoLibrary.fileSize(fromKVC: -5) == nil)
    #expect(PhotoLibrary.fileSize(fromKVC: "x") == nil)
    #expect(PhotoLibrary.fileSize(fromKVC: NSNumber(value: 42)) == 42)
}
