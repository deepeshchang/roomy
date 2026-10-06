import Foundation
import Testing
@testable import VideoCompressor

// MARK: Sort / filter

/// 1080p, 60 s. `compressed` gives ~1 bit/pixel/s, under the "already efficient" line.
private func video(_ id: String, _ bytes: Int64, day: Double = 0, compressed: Bool = false) -> LibraryVideo {
    LibraryVideo(id: id, filename: id, fileSize: compressed ? Int64(1920 * 1080 * 60 / 8) : bytes,
                 duration: 60, creationDate: Date(timeIntervalSince1970: day * 86_400),
                 width: 1920, height: 1080)
}

private let vids = [
    video("big", 3_000_000_000, day: 1),
    video("mid", 600_000_000, day: 3),
    video("small", 200_000_000, day: 2),
    video("done", 0, day: 4, compressed: true),
]

@Test func largestFirstIsNonIncreasingBySize() {
    let out = LibraryQuery(sort: .largest).apply(vids, handled: [])
    #expect(out.map(\.fileSize) == out.map(\.fileSize).sorted(by: >))
    #expect(out.count == 4)
}

@Test func newestFirstSortsByCreationDateDescending() {
    let out = LibraryQuery(sort: .newest).apply(vids, handled: [])
    #expect(out.map(\.id) == ["done", "mid", "small", "big"])
}

@Test func sizeFilterKeepsOnlyItemsAtOrOverTheThreshold() {
    let out = LibraryQuery(sort: .largest, minBytes: 600_000_000).apply(vids, handled: [])
    #expect(out.map(\.id) == ["big", "mid"])
}

@Test func hideCompressedDropsHandledAndEfficientItems() {
    let out = LibraryQuery(sort: .largest, hideCompressed: true).apply(vids, handled: ["mid"])
    #expect(out.map(\.id) == ["big", "small"])
}

@Test func filtersCombineAsAnd() {
    let out = LibraryQuery(sort: .newest, minBytes: 500_000_000, hideCompressed: true)
        .apply(vids, handled: ["big"])
    #expect(out.map(\.id) == ["mid"])
}

@Test func hideCompressedIsOffByDefault() {
    #expect(LibraryQuery().hideCompressed == false)
    #expect(LibraryQuery().isFiltered == false)
    #expect(LibraryQuery(minBytes: 1).isFiltered)
    #expect(LibraryQuery(hideCompressed: true).isFiltered)
}

@Test func sizePresetsDifferPerKind() {
    #expect(LibraryQuery.sizeOptions(for: .video) == [0, 100_000_000, 500_000_000, 1_000_000_000])
    #expect(LibraryQuery.sizeOptions(for: .photo) == [0, 5_000_000, 10_000_000])
}

// MARK: Biggest wins

@Test func biggestWinsTakesTheNLargestEligibleWhateverTheOrder() {
    let many = (1...30).map { video("v\($0)", Int64($0) * 100_000_000, day: Double($0)) }
    let wins = LibraryQuery.biggestWins(many.shuffled(), handled: ["v30"], count: 20)
    #expect(wins.count == 20)
    #expect(wins.first?.id == "v29")
    #expect(wins.last?.id == "v10")
}

@Test func biggestWinsExcludesCompressedAndShrinksToWhatIsEligible() {
    let wins = LibraryQuery.biggestWins(vids, handled: ["small"], count: 20)
    #expect(wins.map(\.id) == ["big", "mid"])
}

// MARK: Large badge

@Test func largeIsOneGigabyteOrTopTenPercent() {
    let sizes: [Int64] = (1...20).map { Int64($0) * 10_000_000 }   // 10 MB … 200 MB
    let cutoff = LibraryQuery.largeCutoff(sizes)
    #expect(cutoff == 190_000_000)                                   // top 2 of 20
    #expect(LibraryQuery.isLarge(200_000_000, cutoff: cutoff))
    #expect(!LibraryQuery.isLarge(180_000_000, cutoff: cutoff))
    #expect(LibraryQuery.isLarge(1_000_000_000, cutoff: .max))
    #expect(LibraryQuery.largeCutoff([]) == .max)
}

// MARK: Savings

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "savings.\(UUID().uuidString)")!
}

@Test func compressingAloneIsReadyToFreeNotSaved() {
    var s = SavingsStats()
    s.recordCompressed(id: "a", kind: .video, savedBytes: 2_000_000_000, copyID: "copy")
    #expect(s.savedBytes == 0)
    #expect(s.readyBytes == 2_000_000_000)
}

@Test func confirmedDeleteMovesReadyIntoSaved() {
    var s = SavingsStats()
    s.recordCompressed(id: "a", kind: .video, savedBytes: 1_500_000_000, copyID: "copy")
    s.recordCompressed(id: "b", kind: .photo, savedBytes: 500_000_000, copyID: "copy")
    s.recordCompressed(id: "c", kind: .video, savedBytes: 100, copyID: "copy")
    s.recordDeleted(ids: ["a", "b", "unknown"], on: Date(timeIntervalSince1970: 0))
    #expect(s.savedBytes == 2_000_000_000)
    #expect(s.videoCount == 1 && s.photoCount == 1)
    #expect(s.readyBytes == 100)
    #expect(s.lastBatchBytes == 2_000_000_000)
}

@Test func deletingTheSameIDTwiceCountsOnce() {
    var s = SavingsStats()
    s.recordCompressed(id: "a", kind: .video, savedBytes: 10, copyID: "copy")
    s.recordDeleted(ids: ["a"])
    s.recordDeleted(ids: ["a"])
    #expect(s.savedBytes == 10 && s.videoCount == 1)
}

@Test func notSmallerAddsNothing() {
    var s = SavingsStats()
    s.recordCompressed(id: "a", kind: .video, savedBytes: 0, copyID: "copy")
    s.recordCompressed(id: "b", kind: .video, savedBytes: -5, copyID: "copy")
    s.recordDeleted(ids: ["a", "b"])
    #expect(s.savedBytes == 0 && s.videoCount == 0 && s.readyBytes == 0)
}

@Test func pruneDropsReadyItemsWhoseOriginalIsGoneWithoutCountingThem() {
    var s = SavingsStats()
    s.recordCompressed(id: "a", kind: .video, savedBytes: 10, copyID: "copy")
    s.recordCompressed(id: "b", kind: .video, savedBytes: 20, copyID: "copy")
    s.prune(keeping: ["b"])
    #expect(s.readyBytes == 20 && s.savedBytes == 0)
    #expect(s.readyIDs == ["b"])
}

@Test func statsPersistAcrossLoadsAndReset() {
    let d = freshDefaults()
    SavingsStats.update(d) {
        $0.recordCompressed(id: "a", kind: .video, savedBytes: 10, copyID: "copy")
        $0.recordCompressed(id: "b", kind: .video, savedBytes: 5, copyID: "copy")
        $0.recordDeleted(ids: ["a"])
    }
    let loaded = SavingsStats.load(d)
    #expect(loaded.savedBytes == 10 && loaded.readyBytes == 5)
    SavingsStats.reset(d)
    #expect(SavingsStats.load(d) == SavingsStats())
}

@Test func savedNeverExceedsOriginalBytesDeleted() {
    var s = SavingsStats()
    var originals: Int64 = 0
    for i in 0..<50 {
        let original = Int64.random(in: 1...5_000_000_000)
        let copy = Int64.random(in: 1...6_000_000_000)
        s.recordCompressed(id: "\(i)", kind: .video, savedBytes: original - copy, copyID: "copy")
        originals += original
    }
    s.recordDeleted(ids: (0..<50).map(String.init))
    #expect(s.savedBytes <= originals && s.savedBytes >= 0)
}
