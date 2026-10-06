import Testing
import Foundation
@testable import VideoCompressor

private func lib(_ name: String, _ size: Int64) -> LibraryVideo {
    LibraryVideo(id: name, filename: name, fileSize: size,
                 duration: 10, creationDate: nil, width: 1920, height: 1080)
}

@Test func sortsLibraryVideosLargestFirst() {
    let sorted = PhotoLibrary.sortedLargestFirst([
        lib("small.mov", 1_000),
        lib("huge.mov", 9_000_000),
        lib("medium.mov", 50_000),
    ])
    #expect(sorted.map(\.filename) == ["huge.mov", "medium.mov", "small.mov"])
}

@Test func equalSizesFallBackToFilenameSoOrderIsStable() {
    let a = PhotoLibrary.sortedLargestFirst([lib("b.mov", 100), lib("a.mov", 100)])
    let b = PhotoLibrary.sortedLargestFirst([lib("a.mov", 100), lib("b.mov", 100)])
    #expect(a.map(\.filename) == ["a.mov", "b.mov"])
    #expect(a.map(\.filename) == b.map(\.filename), "sort must not depend on input order")
}

@Test func sortingAnEmptyLibraryIsSafe() {
    #expect(PhotoLibrary.sortedLargestFirst([]).isEmpty)
}

// The delete gate is the one safety-critical branch in the app: the original
// must never be offered for deletion before its replacement exists.
@MainActor
@Test func deletionIsGatedOnHavingSavedTheCompressedCopy() {
    let item = VideoItem(sourceURL: URL(fileURLWithPath: "/tmp/x.mov"), assetID: "asset-1")

    #expect(!item.canDeleteOriginal, "must not offer deletion before saving")

    item.savedToPhotos = true
    item.savedAssetID = "copy-1"
    #expect(item.canDeleteOriginal, "offered once the copy is in Photos")

    item.originalDeleted = true
    #expect(!item.canDeleteOriginal, "never offered twice")
}

@MainActor
@Test func itemsWithNoLibraryOriginalCanNeverBeDeleted() {
    // A file that did not come from the library has no asset to delete.
    let item = VideoItem(sourceURL: URL(fileURLWithPath: "/tmp/x.mov"), assetID: nil)
    item.savedToPhotos = true
    #expect(!item.canDeleteOriginal)
}

@MainActor
@Test func deleteOriginalRefusesWhenTheGateIsClosed() async throws {
    let store = BatchStore()
    let item = VideoItem(sourceURL: URL(fileURLWithPath: "/tmp/x.mov"), assetID: "asset-1")
    // savedToPhotos is still false.
    let deleted = try await store.deleteOriginal(item)
    #expect(deleted == false)
    #expect(item.originalDeleted == false)
}

@Test func placeholderMetadataIsUsableWithoutLoadingTheVideo() {
    // The list must be usable before anything is decoded or downloaded.
    let video = LibraryVideo(id: "a", filename: "IMG_1.MOV", fileSize: 1_000_000,
                             duration: 10, creationDate: nil, width: 3840, height: 2160)
    let m = video.placeholderMetadata

    #expect(m.filename == "IMG_1.MOV")
    #expect(m.fileSize == 1_000_000)
    #expect(m.resolutionLabel == "3840\u{00D7}2160")
    #expect(m.formattedDuration == "0:10")
    #expect(m.bitrate > 0, "bitrate is derivable from size and duration alone")
    #expect(!m.isHEVC, "codec is unknown until probed locally")
    #expect(!m.isH264)
}

@Test func placeholderBitrateDoesNotDivideByZeroOnAZeroLengthVideo() {
    let video = LibraryVideo(id: "a", filename: "x.mov", fileSize: 100,
                             duration: 0, creationDate: nil, width: 0, height: 0)
    #expect(video.placeholderMetadata.bitrate == 0)
}
