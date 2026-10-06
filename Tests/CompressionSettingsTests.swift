import Testing
import UniformTypeIdentifiers
@testable import VideoCompressor

private func clip(_ w: Int, _ h: Int, seconds: Double) -> VideoMetadata {
    VideoMetadata(filename: "a.mov", fileSize: 2_000_000_000, duration: seconds,
                  width: w, height: h, frameRate: 30, codec: "avc1", bitrate: 0)
}

private func photo(_ w: Int, _ h: Int, sizeMB: Int64 = 20) -> LibraryPhoto {
    LibraryPhoto(id: "p", filename: "p.jpg", fileSize: sizeMB * 1_000_000, width: w, height: h,
                 creationDate: nil, uti: UTType.jpeg.identifier, isLivePhoto: false)
}

@Test func presetsAreOrderedFromBiggestToSmallest() {
    let sizes = [VideoPreset.high, .balanced, .maximum].map(\.tenMinuteExampleBytes)
    #expect(sizes[0] > sizes[1] && sizes[1] > sizes[2])
}

@Test func presetExampleComesFromTheRealPlan() {
    let plan = CompressionSettings(videoPreset: .balanced).videoPlan(for: VideoPreset.exampleClip)
    #expect(VideoPreset.balanced.tenMinuteExampleBytes == plan.estimatedBytes)
    let mb = plan.estimatedBytes / 1_000_000
    #expect(mb > 170 && mb < 230, "balanced 10-minute clip was \(mb) MB")
}

@Test func presetsScaleWithLength() {
    let s = CompressionSettings(videoPreset: .balanced)
    let short = s.videoPlan(for: clip(1920, 1080, seconds: 60)).estimatedBytes
    let long = s.videoPlan(for: clip(1920, 1080, seconds: 600)).estimatedBytes
    #expect(long > short * 8, "a preset is a rate, so 10x longer should be ~10x bigger")
}

@Test func advancedTargetKeepsTheOldBehaviour() {
    let s = CompressionSettings(videoPreset: .custom, target: .mb50)
    let m = clip(1920, 1080, seconds: 600)
    #expect(s.videoPlan(for: m) == CompressionPlan.plan(for: m, target: .mb50))
}

@Test func downscaleToggleControlsPhotoResolution() {
    let big = photo(8000, 6000)
    #expect(CompressionSettings(downscaleLargePhotos: true).photoPlan(for: big).maxLongEdge == 4032)
    #expect(CompressionSettings(downscaleLargePhotos: false).photoPlan(for: big).maxLongEdge == nil)
}

@Test func highPhotoQualityEncodesHigherAndEstimatesBigger() {
    let p = photo(4032, 3024)
    let high = CompressionSettings(photoQuality: .high).photoPlan(for: p)
    let balanced = CompressionSettings(photoQuality: .balanced).photoPlan(for: p)
    #expect(high.quality > balanced.quality)
    #expect(high.estimatedBytes > balanced.estimatedBytes)
}

@Test func selectionEstimateFollowsTheSettings() {
    let v = LibraryVideo(id: "v", filename: "v.mov", fileSize: 2_000_000_000, duration: 600,
                         creationDate: nil, width: 1920, height: 1080)
    let more = LibrarySelection.estimatedFreed(videos: [v], photos: [],
                                               settings: CompressionSettings(videoPreset: .maximum))
    let less = LibrarySelection.estimatedFreed(videos: [v], photos: [],
                                               settings: CompressionSettings(videoPreset: .high))
    #expect(more > less)
}
