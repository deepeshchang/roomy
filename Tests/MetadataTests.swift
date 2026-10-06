import Testing
import AVFoundation
import CoreLocation
@testable import VideoCompressor

private func value(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) -> String? {
    items.first { $0.identifier == id }?.value as? String
}

@Test func keepsTheSourceCreationDateVerbatim() {
    // The source string carries the original timezone; it must not be rewritten.
    let original = AVMutableMetadataItem()
    original.identifier = .quickTimeMetadataCreationDate
    original.value = "2024-03-09T18:42:07+0530" as NSString

    let items = PhotoLibrary.quickTimeMetadata(source: [original],
                                               creationDate: Date(timeIntervalSince1970: 0),
                                               location: nil)

    #expect(value(items, .quickTimeMetadataCreationDate) == "2024-03-09T18:42:07+0530")
    #expect(items.filter { $0.identifier == .quickTimeMetadataCreationDate }.count == 1,
            "must not add a second, conflicting creation date")
}

@Test func synthesisesACreationDateWhenTheFileHasNone() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let items = PhotoLibrary.quickTimeMetadata(source: [], creationDate: date, location: nil)

    let written = try? #require(value(items, .quickTimeMetadataCreationDate))
    let parsed = written.flatMap { ISO8601DateFormatter().date(from: $0) }
    #expect(parsed == date, "the synthesised date must round-trip to the same instant")
}

@Test func writesGPSInISO6709WhenMissing() {
    let loc = CLLocation(coordinate: .init(latitude: 12.9716, longitude: 77.5946),
                         altitude: 920, horizontalAccuracy: 5, verticalAccuracy: 5,
                         timestamp: .now)
    let items = PhotoLibrary.quickTimeMetadata(source: [], creationDate: nil, location: loc)
    #expect(value(items, .quickTimeMetadataLocationISO6709) == "+12.9716+077.5946+920.000/")
}

@Test func iso6709HandlesSouthAndWest() {
    let loc = CLLocation(coordinate: .init(latitude: -33.8688, longitude: -151.2093),
                         altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                         timestamp: .now)
    #expect(PhotoLibrary.iso6709(loc) == "-33.8688-151.2093+000.000/")
}

@Test func addsNothingWhenThereIsNothingToAdd() {
    #expect(PhotoLibrary.quickTimeMetadata(source: [], creationDate: nil, location: nil).isEmpty)
}

@MainActor
@Test func compressedFileCarriesTheMetadataIntoTheOutput() async throws {
    let source = try await FixtureVideo.make(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: source) }

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let loc = CLLocation(latitude: 12.9716, longitude: 77.5946)
    let metadata = PhotoLibrary.quickTimeMetadata(source: [], creationDate: date, location: loc)

    let probed = try await VideoProbe.probe(url: source)
    let output = try await VideoCompressorEngine().compress(
        asset: AVAssetBox(asset: AVURLAsset(url: source)), basename: "meta",
        plan: CompressionPlan.plan(for: probed, target: .mb200),
        metadata: MetadataBox(metadata)) { _ in }
    defer { try? FileManager.default.removeItem(at: output) }

    let written = try await AVURLAsset(url: output).load(.metadata)
    let dateItem = written.first { $0.identifier == .quickTimeMetadataCreationDate }
    let gpsItem = written.first { $0.identifier == .quickTimeMetadataLocationISO6709 }
    #expect(dateItem != nil, "creation date must survive the re-encode")
    #expect(gpsItem != nil, "location must survive the re-encode")
}
