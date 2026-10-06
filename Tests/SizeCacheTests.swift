import Testing
import Foundation
@testable import VideoCompressor

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func aCachedSizeIsReusedWhileTheAssetIsUnchanged() {
    var cache = SizeCache()
    cache.store("a", modified: t0, size: 5_000, filename: "a.mov", uti: nil)
    #expect(cache.lookup("a", modified: t0)?.size == 5_000)
}

@Test func anEditedAssetIsReadAgain() {
    // Editing a photo or video changes its modification date — and its size.
    var cache = SizeCache()
    cache.store("a", modified: t0, size: 5_000, filename: "a.mov", uti: nil)
    #expect(cache.lookup("a", modified: t0.addingTimeInterval(60)) == nil)
}

@Test func unknownAssetsMiss() {
    #expect(SizeCache().lookup("nope", modified: t0) == nil)
}

@Test func assetsWithNoModificationDateAreNeverServedFromTheCache() {
    // No date means no way to know the asset is unchanged, so always re-read.
    var cache = SizeCache()
    cache.store("a", modified: nil, size: 7, filename: "a", uti: nil)
    #expect(cache.lookup("a", modified: nil) == nil)

    var reads = 0
    let read = { () -> (size: Int64, filename: String, uti: String?, measured: Bool) in
        reads += 1; return (10, "b", nil, true)
    }
    _ = cache.resolve("b", modified: nil, read: read)
    let again = cache.resolve("b", modified: nil, read: read)
    #expect(!again.hit)
    #expect(reads == 2)
}

@Test func pruningDropsDeletedAssets() {
    var cache = SizeCache()
    cache.store("keep", modified: t0, size: 1, filename: "k", uti: nil)
    cache.store("gone", modified: t0, size: 1, filename: "g", uti: nil)
    cache.prune(keeping: ["keep"])
    #expect(cache.lookup("keep", modified: t0) != nil)
    #expect(cache.lookup("gone", modified: t0) == nil)
}

@Test func theCacheSurvivesARoundTripToDisk() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sizecache-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    var cache = SizeCache()
    cache.store("a", modified: t0, size: 123, filename: "a.mov", uti: "com.apple.quicktime-movie")
    try cache.save(to: url)

    let loaded = SizeCache.load(from: url)
    #expect(loaded.lookup("a", modified: t0)?.size == 123)
    #expect(loaded.lookup("a", modified: t0)?.uti == "com.apple.quicktime-movie")
}

@Test func aMissingOrCorruptFileLoadsEmptyRatherThanFailing() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID()).plist")
    #expect(SizeCache.load(from: missing).isEmpty)

    let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).plist")
    try Data("garbage".utf8).write(to: corrupt)
    defer { try? FileManager.default.removeItem(at: corrupt) }
    #expect(SizeCache.load(from: corrupt).isEmpty, "a bad cache must cost a rescan, never a crash")
}

@Test func mergingFreshEntriesAddsThem() {
    var cache = SizeCache()
    var fresh = SizeCache()
    fresh.store("b", modified: t0, size: 9, filename: "b", uti: nil)
    cache.merge(fresh)
    #expect(cache.lookup("b", modified: t0)?.size == 9)
}

@Test func aMeasuredSizeIsStoredSoASecondScanReadsNoResources() {
    var cache = SizeCache()
    var reads = 0
    let read = { () -> (size: Int64, filename: String, uti: String?, measured: Bool) in
        reads += 1; return (10, "a.mov", nil, true)
    }
    let first = cache.resolve("a", modified: t0, read: read)
    let second = cache.resolve("a", modified: t0, read: read)
    #expect(!first.hit && second.hit)
    #expect(reads == 1)
    #expect(second.entry.size == 10)
}

@Test func anEstimatedSizeIsUsedButNeverCached() {
    // A guess cached under an unchanged modification date would be reused forever.
    var cache = SizeCache()
    var reads = 0
    let read = { () -> (size: Int64, filename: String, uti: String?, measured: Bool) in
        reads += 1; return (999, "icloud.mov", nil, false)
    }
    let first = cache.resolve("a", modified: t0, read: read)
    let second = cache.resolve("a", modified: t0, read: read)
    #expect(first.entry.size == 999)
    #expect(!first.hit && !second.hit)
    #expect(reads == 2)
    #expect(cache.lookup("a", modified: t0) == nil)
}

@Test func limitedAccessOrAnEmptyFetchNeverPrunes() {
    #expect(!SizeCache.shouldPrune(authorizationLimited: true, total: 100))
    #expect(!SizeCache.shouldPrune(authorizationLimited: false, total: 0))
    #expect(SizeCache.shouldPrune(authorizationLimited: false, total: 100))
}

@Test func aScanOnlyWritesBackItsOwnKind() {
    // The photo scan started with both kinds, then the video scan pruned "v:gone" on disk.
    var startOfPhotoScan = SizeCache()
    startOfPhotoScan.store("v:gone", modified: t0, size: 1, filename: "g", uti: nil)
    startOfPhotoScan.store("p:new", modified: t0, size: 2, filename: "n", uti: nil)

    var disk = SizeCache()   // state after the video scan pruned v:gone
    disk.merge(startOfPhotoScan.entries(withPrefix: "p:"))

    #expect(disk.lookup("v:gone", modified: t0) == nil, "a stale copy of the other kind must not reappear")
    #expect(disk.lookup("p:new", modified: t0) != nil)
}
