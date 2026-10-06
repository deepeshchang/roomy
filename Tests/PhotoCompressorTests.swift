import Testing
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import VideoCompressor

// MARK: - Fixtures

/// A JPEG with EXIF date and GPS, so metadata preservation can be checked.
private func makeJPEG(width: Int, height: Int) throws -> Data {
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // A gradient, so the encoder has real detail to work with.
    for y in 0..<height where y % 4 == 0 {
        context.setFillColor(red: Double(y) / Double(height), green: 0.3, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: y, width: width, height: 4))
    }
    let image = context.makeImage()!

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:03:09 18:42:07",
        ] as CFDictionary,
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 12.9716,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 77.5946,
            kCGImagePropertyGPSLongitudeRef: "E",
        ] as CFDictionary,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PhotoCompressionError.encodeFailed }
    return data as Data
}

private func properties(of url: URL) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
    else { return [:] }
    return (props as? [CFString: Any]) ?? [:]
}

// MARK: - Planning

private func photo(_ uti: String, w: Int, h: Int, sizeMB: Double) -> LibraryPhoto {
    LibraryPhoto(id: "a", filename: "IMG.x", fileSize: Int64(sizeMB * 1_000_000),
                 width: w, height: h, creationDate: nil, uti: uti, isLivePhoto: false)
}

@Test func screenshotsAreExpectedToCollapse() {
    let plan = PhotoPlan.plan(for: photo(UTType.png.identifier, w: 1179, h: 2556, sizeMB: 3))
    #expect(plan.estimatedBytes < 600_000, "a 3 MB PNG should land well under 1 MB")
}

@Test func jpegIsExpectedToRoughlyHalveOrBetter() {
    let plan = PhotoPlan.plan(for: photo(UTType.jpeg.identifier, w: 4032, h: 3024, sizeMB: 4))
    #expect(plan.estimatedBytes < 2_000_000)
    #expect(plan.estimatedBytes > 500_000)
}

@Test func rawFilesPromiseTheBiggestSaving() {
    let raw = PhotoPlan.plan(for: photo("com.adobe.raw-image", w: 6000, h: 4000, sizeMB: 50))
    #expect(raw.maxLongEdge == PhotoPlan.defaultLongEdgeCap, "6000px must be capped")
    #expect(raw.estimatedBytes < 4_000_000, "50 MB RAW should come down dramatically")
}

@Test func photosAlreadySmallEnoughAreNotDownscaled() {
    let plan = PhotoPlan.plan(for: photo(UTType.jpeg.identifier, w: 3024, h: 4032, sizeMB: 3))
    #expect(plan.maxLongEdge == nil, "4032px is already the cap; don't resample")
}

@Test func normalIPhoneHEICPhotosAreStillCandidates() {
    // Regression: treating "is HEIC" as "already compressed" hid the whole
    // library, because every iPhone photo is HEIC.
    let heic = photo(UTType.heic.identifier, w: 4032, h: 3024, sizeMB: 2)
    #expect(!heic.looksAlreadyCompressed, "a 2 MB iPhone HEIC still has ~40% to give")
    let big = photo(UTType.heic.identifier, w: 8000, h: 6000, sizeMB: 20)
    #expect(!big.looksAlreadyCompressed)
}

@Test func tinyPhotosAreSkipped() {
    // A 40 KB thumbnail-sized image has nothing worth reclaiming.
    let small = LibraryPhoto(id: "s", filename: "s.jpg", fileSize: 40_000,
                             width: 400, height: 300, creationDate: nil,
                             uti: UTType.jpeg.identifier, isLivePhoto: false)
    #expect(small.looksAlreadyCompressed)
}

@Test func photosWithNoRealGainAreSkipped() {
    // Contrived: a format whose ratio leaves under 15% on the table.
    let plan = PhotoPlan.plan(for: photo(UTType.heic.identifier, w: 100, h: 100, sizeMB: 1))
    let fraction = 1.0 - Double(plan.estimatedBytes) / 1_000_000
    #expect(fraction > PhotoPlan.minimumSavingFraction,
            "sanity: HEIC ratio must clear the bar, or nothing is ever offered")
}

@Test func rawAndLiveFlagsAreDetected() {
    #expect(photo("com.adobe.raw-image", w: 100, h: 100, sizeMB: 1).isRAW)
    #expect(!photo(UTType.jpeg.identifier, w: 100, h: 100, sizeMB: 1).isRAW)
}

@Test func photoCandidatesDropHandledAndAlreadyCompressed() {
    let list = [
        photo(UTType.jpeg.identifier, w: 4032, h: 3024, sizeMB: 4),
        LibraryPhoto(id: "done", filename: "b", fileSize: 1, width: 100, height: 100,
                     creationDate: nil, uti: UTType.jpeg.identifier, isLivePhoto: false),
        LibraryPhoto(id: "tiny", filename: "c", fileSize: 1, width: 100, height: 100,
                     creationDate: nil, uti: UTType.heic.identifier, isLivePhoto: false),
    ]
    #expect(LibraryPhoto.candidates(list, handled: ["done"]).map(\.id) == ["a"])
}

// MARK: - Encoding

@Test func reEncodesJPEGToASmallerHEIC() throws {
    let jpeg = try makeJPEG(width: 2000, height: 1500)
    let plan = PhotoPlan(maxLongEdge: nil, quality: 0.8, estimatedBytes: 0)

    let output = try PhotoCompressorEngine().compress(data: jpeg, plan: plan, basename: "t")
    defer { try? FileManager.default.removeItem(at: output) }

    let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 ?? 0
    #expect(size > 0)
    #expect(size < Int64(jpeg.count), "HEIC should be smaller: \(size) vs \(jpeg.count)")

    let props = properties(of: output)
    #expect((props[kCGImagePropertyPixelWidth] as? Int) == 2000)
    #expect((props[kCGImagePropertyPixelHeight] as? Int) == 1500)
}

@Test func preservesDateAndGPS() throws {
    let jpeg = try makeJPEG(width: 800, height: 600)
    let output = try PhotoCompressorEngine().compress(
        data: jpeg, plan: PhotoPlan(maxLongEdge: nil, quality: 0.8, estimatedBytes: 0),
        basename: "t")
    defer { try? FileManager.default.removeItem(at: output) }

    let props = properties(of: output)
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:03:09 18:42:07",
            "the capture date must survive, or photos sort to the wrong place")
    #expect(gps?[kCGImagePropertyGPSLatitude] != nil, "GPS must survive")
}

@Test func downscalesToTheCapAndKeepsAspectRatio() throws {
    let jpeg = try makeJPEG(width: 6000, height: 4000)
    let plan = PhotoPlan(maxLongEdge: 4032, quality: 0.8, estimatedBytes: 0)

    let output = try PhotoCompressorEngine().compress(data: jpeg, plan: plan, basename: "t")
    defer { try? FileManager.default.removeItem(at: output) }

    let props = properties(of: output)
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    #expect(max(w, h) == 4032, "expected long edge 4032, got \(w)x\(h)")
    #expect(abs(Double(w) / Double(h) - 1.5) < 0.01, "6000x4000 is 3:2")
}

@Test func rejectsDataThatIsNotAnImage() {
    #expect(throws: (any Error).self) {
        _ = try PhotoCompressorEngine().compress(
            data: Data("not an image".utf8),
            plan: PhotoPlan(maxLongEdge: nil, quality: 0.8, estimatedBytes: 0),
            basename: "t")
    }
}
