import Testing
@testable import VideoCompressor

private let items: [(id: String, bytes: Int64)] = [
    ("a", 3_000_000_000), ("b", 2_000_000_000), ("c", 1_000_000_000), ("d", 500_000_000),
]

@Test func tapTogglesAnItem() {
    var s = LibrarySelection()
    s.toggle("a")
    #expect(s.ids == ["a"])
    s.toggle("a")
    #expect(s.ids.isEmpty)
}

@Test func topNReplacesTheVisibleSelectionButKeepsTheOtherKind() {
    var s = LibrarySelection(ids: ["photo1", "d"])
    s.selectTop(2, of: items)
    #expect(s.ids == ["photo1", "a", "b"])
}

@Test func topNLargerThanTheListSelectsEverythingVisible() {
    var s = LibrarySelection()
    s.selectTop(100, of: items)
    #expect(s.ids == ["a", "b", "c", "d"])
}

@Test func overOneGigabyteIsStrictlyOver() {
    var s = LibrarySelection()
    s.selectOver(1_000_000_000, of: items)
    #expect(s.ids == ["a", "b"])
}

@Test func selectFromHereAddsThatItemAndEverythingAfterIt() {
    var s = LibrarySelection(ids: ["a"])
    s.selectFrom("c", of: items)
    #expect(s.ids == ["a", "c", "d"])
}

@Test func deselectAllClearsBothKinds() {
    var s = LibrarySelection(ids: ["photo1", "a"])
    s.deselectAll()
    #expect(s.ids.isEmpty)
}

@Test func pruningDropsHiddenItemsAndReportsHowMany() {
    var s = LibrarySelection(ids: ["a", "b", "photo1"])
    let removed = s.prune(keeping: ["a", "photo1"])
    #expect(removed == 1)
    #expect(s.ids == ["a", "photo1"])
}

@Test func freedEstimateSumsVideosAndPhotos() {
    let video = LibraryVideo(id: "v", filename: "v.mov", fileSize: 1_800_000_000, duration: 600,
                             creationDate: nil, width: 1920, height: 1080)
    let photo = LibraryPhoto(id: "p", filename: "p.dng", fileSize: 40_000_000, width: 6000,
                             height: 4000, creationDate: nil, uti: "com.adobe.raw-image",
                             isLivePhoto: false)
    let videoSaving = SavingsEstimator.estimate(
        for: video.placeholderMetadata,
        plan: CompressionPlan.plan(for: video.placeholderMetadata, target: .mb200)).savedBytes
    let photoSaving = photo.fileSize - PhotoPlan.plan(for: photo).estimatedBytes

    let freed = LibrarySelection.estimatedFreed(videos: [video], photos: [photo],
                                               settings: CompressionSettings(videoPreset: .custom, target: .mb200))
    #expect(freed == videoSaving + photoSaving)
    #expect(freed > 1_500_000_000)
}
