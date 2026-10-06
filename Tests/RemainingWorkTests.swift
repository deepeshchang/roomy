import Testing
import Foundation
@testable import VideoCompressor

// MARK: Drag-to-select

private let grid: [LibrarySelection.Item] = (0..<6).map { ("v\($0)", Int64(100 - $0)) }

@Test func dragFromAnUnselectedCellSelectsTheRange() {
    var s = LibrarySelection()
    s.drag(from: "v1", to: "v3", in: grid, base: [])
    #expect(s.ids == ["v1", "v2", "v3"])
}

@Test func dragWorksBackwardsToo() {
    var s = LibrarySelection()
    s.drag(from: "v4", to: "v2", in: grid, base: [])
    #expect(s.ids == ["v2", "v3", "v4"])
}

@Test func draggingBackShrinksTheRangeAgain() {
    // The range is recomputed from the drag's starting selection every time,
    // so moving the finger back un-selects what it passed over.
    var s = LibrarySelection()
    s.drag(from: "v0", to: "v4", in: grid, base: [])
    s.drag(from: "v0", to: "v1", in: grid, base: [])
    #expect(s.ids == ["v0", "v1"])
}

@Test func dragFromASelectedCellDeselectsAndKeepsTheRest() {
    var s = LibrarySelection(ids: ["v0", "v1", "v2", "v5"])
    s.drag(from: "v1", to: "v2", in: grid, base: s.ids)
    #expect(s.ids == ["v0", "v5"])
}

@Test func dragOutsideTheVisibleListChangesNothing() {
    var s = LibrarySelection(ids: ["v0"])
    s.drag(from: "missing", to: "v3", in: grid, base: s.ids)
    #expect(s.ids == ["v0"])
}

// MARK: Retry and undo

@MainActor
@Test func retryingAFailedItemPutsItBackInTheQueue() {
    let store = BatchStore()
    let item = VideoItem(sourceURL: nil, assetID: "a")
    item.state = .failed("network")
    store.items = [item]
    store.hasStarted = true
    #expect(store.phase == .done)

    store.retry(item)
    #expect(item.state == .ready)
    #expect(store.phase == .stopped, "a retried item is work waiting to run")
}

@MainActor
@Test func retryAllOnlyTouchesFailedItems() {
    let store = BatchStore()
    let failed = VideoItem(sourceURL: nil, assetID: "a"); failed.state = .failed("x")
    let done = VideoItem(sourceURL: nil, assetID: "b"); done.state = .finished
    let small = VideoItem(sourceURL: nil, assetID: "c"); small.state = .alreadySmall
    store.items = [failed, done, small]
    store.retryAllFailed()
    #expect(failed.state == .ready)
    #expect(done.state == .finished)
    #expect(small.state == .alreadySmall)
}

@MainActor
@Test func removingInReviewCanBeUndoneInPlace() {
    let store = BatchStore()
    let a = VideoItem(sourceURL: nil, assetID: "a")
    let b = VideoItem(sourceURL: nil, assetID: "b")
    let c = VideoItem(sourceURL: nil, assetID: "c")
    store.items = [a, b, c]

    store.remove(b)
    #expect(store.items.map(\.assetID) == ["a", "c"])
    #expect(store.canUndoRemove)

    store.undoRemove()
    #expect(store.items.map(\.assetID) == ["a", "b", "c"], "back in its original place")
    #expect(!store.canUndoRemove)
}

// MARK: Orphaned working files

@Test func orphanedPartialFilesAreRemovedButReferencedOnesKept() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orphans-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["keep.mov", "partial-1.mov", "partial-2.heic"] {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    let removed = BatchStore.removeOrphans(in: dir, keeping: ["keep.mov"])

    #expect(removed == 2)
    let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(left == ["keep.mov"])
}

@Test func orphanCleanupOnAMissingDirectoryIsHarmless() {
    let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(BatchStore.removeOrphans(in: dir, keeping: []) == 0)
}

// MARK: Time remaining

@Test func noEstimateUntilThereIsEnoughToGoOn() {
    var eta = ETAEstimator()
    #expect(eta.update(fraction: 0.01, elapsed: 30) == nil, "too little progress")
    #expect(eta.update(fraction: 0.5, elapsed: 1) == nil, "too little time")
}

@Test func steadyProgressGivesASteadyEstimate() {
    var eta = ETAEstimator()
    let first = eta.update(fraction: 0.25, elapsed: 60)     // 4 min total
    let second = eta.update(fraction: 0.5, elapsed: 120)
    #expect(first.map { abs($0 - 180) < 1 } == true)
    #expect(second.map { abs($0 - 120) < 1 } == true)
}

@Test func aWildSwingIsHiddenRatherThanShown() {
    // A sudden jump (e.g. a tiny clip after a huge one) must not flash a
    // misleading number; it is suppressed for that reading.
    var eta = ETAEstimator()
    _ = eta.update(fraction: 0.25, elapsed: 60)              // ~180 s left
    #expect(eta.update(fraction: 0.26, elapsed: 600) == nil) // ~1700 s: >50% swing
}

@Test func formatsRemainingTimeForPeople() {
    #expect(ETAEstimator.text(for: 20) == "Less than a minute left")
    #expect(ETAEstimator.text(for: 150) == "About 3 min left")
    #expect(ETAEstimator.text(for: 3 * 3600 + 600) == "About 3 hr 10 min left")
}
