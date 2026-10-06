import Testing
import Foundation
@testable import VideoCompressor

private let meta = VideoMetadata(filename: "v.mov", fileSize: 1_000_000_000, duration: 60,
                                 width: 1920, height: 1080, frameRate: 30, codec: "avc1", bitrate: 0)

@MainActor
private func item(_ id: String, _ state: ItemState, saved: Bool = false) -> VideoItem {
    let i = VideoItem(sourceURL: nil, assetID: id)
    i.metadata = meta
    i.state = state
    i.savedToPhotos = saved
    if saved { i.outputSize = 100_000_000; i.savedAssetID = "copy-\(id)" }
    return i
}

@MainActor
private func roundTrip(_ store: BatchStore) -> BatchStore {
    let restored = BatchStore()
    restored.restore(store.snapshot)
    return restored
}

@MainActor
@Test func finishedSavedItemsStayFinishedWithTheirSaving() {
    let store = BatchStore()
    store.items = [item("a", .finished, saved: true)]
    let r = roundTrip(store).items[0]
    #expect(r.state == .finished)
    #expect(r.savedToPhotos)
    #expect(r.savedAssetID == "copy-a")
    #expect(r.actualSavedBytes == 900_000_000)
    #expect(r.canDeleteOriginal)
}

@MainActor
@Test func interruptedItemsGoBackToReady() {
    let store = BatchStore()
    store.items = [item("a", .compressing), item("b", .downloading(0.4)),
                   item("c", .finished, saved: false), item("d", .ready)]
    let r = roundTrip(store)
    #expect(r.items.map(\.state) == [.ready, .ready, .ready, .ready])
    #expect(r.items.map(\.assetID) == ["a", "b", "c", "d"])
    #expect(r.items[0].estimate != nil, "restored items need an estimate to show")
}

@MainActor
@Test func failedItemsKeepTheirReason() {
    let store = BatchStore()
    store.items = [item("a", .failed("Too big"))]
    #expect(roundTrip(store).items[0].state == .failed("Too big"))
}

@MainActor
@Test func photosKeepTheirKindAndDescription() {
    let p = LibraryPhoto(id: "p", filename: "p.jpg", fileSize: 5_000_000, width: 4032, height: 3024,
                         creationDate: Date(timeIntervalSince1970: 0), uti: "public.jpeg", isLivePhoto: true)
    let store = BatchStore()
    let i = VideoItem(sourceURL: nil, assetID: "p", kind: .photo, photo: p)
    i.state = .ready
    store.items = [i]
    let r = roundTrip(store).items[0]
    #expect(r.kind == .photo)
    #expect(r.photo == p)
}

@MainActor
@Test func deletedOriginalsAreRemembered() {
    let store = BatchStore()
    let i = item("a", .finished, saved: true)
    i.originalDeleted = true
    store.items = [i]
    #expect(roundTrip(store).items[0].originalDeleted)
}

@MainActor
@Test func librarySelectionIsRestored() {
    let store = BatchStore()
    store.selection = LibrarySelection(ids: ["x", "y"])
    #expect(roundTrip(store).selection.ids == ["x", "y"])
}

@MainActor
@Test func saveAndLoadThroughAFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("batch-\(UUID().uuidString)/batch.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = BatchStore(saveURL: url)
    store.items = [item("a", .finished, saved: true), item("b", .ready)]
    store.selection = LibrarySelection(ids: ["z"])
    store.save()

    let next = BatchStore(saveURL: url)
    next.restoreFromDisk()
    #expect(next.items.map(\.assetID) == ["a", "b"])
    #expect(next.selection.ids == ["z"])
}

@MainActor
@Test func missingOrCorruptFileRestoresNothing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
    let store = BatchStore(saveURL: url)
    store.restoreFromDisk()
    #expect(store.items.isEmpty)
    try Data("garbage".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    store.restoreFromDisk()
    #expect(store.items.isEmpty)
}

@MainActor
@Test func clearingEmptiesTheSavedBatch() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = BatchStore(saveURL: url)
    store.items = [item("a", .ready)]
    store.save()
    store.clear()
    let next = BatchStore(saveURL: url)
    next.restoreFromDisk()
    #expect(next.items.isEmpty)
}
