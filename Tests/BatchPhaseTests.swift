import Testing
import Foundation
@testable import VideoCompressor

@MainActor
private func item(_ state: ItemState, size: Int64 = 1_000, out: Int64? = nil,
                  saved: Bool = false) -> VideoItem {
    let photo = LibraryPhoto(id: UUID().uuidString, filename: "a.jpg", fileSize: size,
                             width: 10, height: 10, creationDate: nil, uti: nil,
                             isLivePhoto: false)
    let i = VideoItem(sourceURL: nil, assetID: photo.id, kind: .photo, photo: photo)
    i.state = state
    i.outputSize = out
    i.savedToPhotos = saved
    if saved { i.savedAssetID = "copy-\(photo.id)" }
    return i
}

@MainActor
@Test func phaseIsReviewBeforeAnythingStarts() {
    let store = BatchStore()
    store.items = [item(.ready), item(.ready)]
    #expect(store.phase == .review)
}

@MainActor
@Test func phaseIsStoppedWhenSomeFinishedAndSomeStillReady() {
    let store = BatchStore()
    store.items = [item(.finished, out: 10), item(.ready)]
    store.hasStarted = true
    #expect(store.phase == .stopped)
}

@MainActor
@Test func phaseIsDoneWhenNothingIsLeftReady() {
    let store = BatchStore()
    store.items = [item(.finished, out: 10), item(.failed("x"))]
    store.hasStarted = true
    #expect(store.phase == .done)
}

@MainActor
@Test func summaryCountsFinishedSkippedAndRemaining() {
    let store = BatchStore()
    store.items = [item(.finished, out: 10), item(.finished, out: 10),
                   item(.failed("x")), item(.ready)]
    #expect(store.finishedCount == 2)
    #expect(store.skippedCount == 1)
    #expect(store.remainingCount == 1)
}

@MainActor
@Test func deleteTotalsCoverOnlyDeletableItems() {
    let store = BatchStore()
    store.items = [item(.finished, size: 1_000, out: 100, saved: true),
                   item(.finished, size: 500, out: 400, saved: true),
                   item(.finished, size: 900, out: 100, saved: false),
                   item(.failed("x"))]
    #expect(store.deletableCount == 2)
    #expect(store.deletableFreedBytes == 1_000)
    #expect(store.excludedFromDeleteCount == 2)
}

@MainActor
@Test func removingAnItemDropsItFromTheBatch() {
    let store = BatchStore()
    let a = item(.ready), b = item(.ready)
    store.items = [a, b]
    store.remove(a)
    #expect(store.items.map(\.id) == [b.id])
}
