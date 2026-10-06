import Testing
import Foundation
import CoreGraphics
@testable import VideoCompressor

@MainActor
@Test func addingFilesProbesThemAndProducesEstimates() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }

    let store = BatchStore()
    await store.add(urls: [url])

    #expect(store.items.count == 1)
    let item = try #require(store.items.first)
    #expect(item.metadata != nil)
    #expect(item.estimate != nil)
    #expect(item.state == .ready)
}

@MainActor
@Test func aBadFileFailsWithoutBreakingTheBatch() async throws {
    let good = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    let bad = FileManager.default.temporaryDirectory
        .appendingPathComponent("junk-\(UUID().uuidString).mov")
    try Data("nope".utf8).write(to: bad)
    defer {
        try? FileManager.default.removeItem(at: good)
        try? FileManager.default.removeItem(at: bad)
    }

    let store = BatchStore()
    await store.add(urls: [bad, good])

    #expect(store.items.count == 2)
    let states = store.items.map(\.state)
    #expect(states.contains(.ready), "the good file must still become ready")
    #expect(states.contains { if case .failed = $0 { true } else { false } },
            "the bad file must be marked failed")
}

@MainActor
@Test func compressingTheBatchFinishesEveryReadyItem() async throws {
    let a = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    let b = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer {
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
    }

    let store = BatchStore()
    store.target = .mb200
    await store.add(urls: [a, b])
    await store.compressAll()

    #expect(!store.isCompressing)
    for item in store.items {
        #expect(item.state == .finished, "expected finished, got \(item.state)")
        #expect(item.outputURL != nil)
        #expect(item.progress == 1.0)
    }
}

@MainActor
@Test func clearingRemovesItemsAndWorkingFiles() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }

    let store = BatchStore()
    await store.add(urls: [url])
    await store.compressAll()

    let output = try #require(store.items.first?.outputURL)
    #expect(FileManager.default.fileExists(atPath: output.path))

    store.clear()

    #expect(store.items.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: output.path),
            "clearing must delete our working files")
    #expect(FileManager.default.fileExists(atPath: url.path),
            "clearing must never delete the source")
}

@MainActor
@Test func totalSavedBytesSumsOnlyFinishedItems() async throws {
    let url = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: url) }

    let store = BatchStore()
    await store.add(urls: [url])
    #expect(store.totalSavedBytes == 0, "nothing is finished yet")

    await store.compressAll()
    #expect(store.totalSavedBytes >= 0)
}

@MainActor
@Test func sortingBySizeOrdersLargestFirstWithoutLosingPickedOrder() async throws {
    let small = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    let large = try await FixtureVideo.make(seconds: 2, size: CGSize(width: 1280, height: 720))
    defer {
        try? FileManager.default.removeItem(at: small)
        try? FileManager.default.removeItem(at: large)
    }

    let store = BatchStore()
    await store.add(urls: [small, large])   // deliberately smallest first

    #expect(store.displayItems.map(\.id) == store.items.map(\.id),
            "unsorted must preserve the picked order")

    store.sortedBySize = true
    let sizes = store.displayItems.map { $0.metadata?.fileSize ?? 0 }
    #expect(sizes == sizes.sorted(by: >), "largest must come first")
    #expect(store.displayItems.first?.sourceURL == large)

    store.sortedBySize = false
    #expect(store.displayItems.first?.sourceURL == small,
            "toggling back must restore the picked order")
}
