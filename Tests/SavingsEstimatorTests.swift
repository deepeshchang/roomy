import Testing
@testable import VideoCompressor

private func meta(fileSize: Int64, seconds: Double = 600) -> VideoMetadata {
    VideoMetadata(filename: "x.mov", fileSize: fileSize, duration: seconds,
                  width: 1920, height: 1080, frameRate: 30,
                  codec: "h264", bitrate: 0)
}

@Test func reportsTheSavingAgainstThePlannedSize() {
    let m = meta(fileSize: 1_800_000_000)
    let plan = CompressionPlan.plan(for: m, target: .mb200)
    let e = SavingsEstimator.estimate(for: m, plan: plan)

    #expect(e.estimatedBytes == plan.estimatedBytes)
    #expect(e.savedBytes == m.fileSize - plan.estimatedBytes)
    #expect(e.savedFraction > 0.85, "1.8 GB down to ~200 MB is a big win")
    #expect(e.isWorthwhile)
}

@Test func neverReportsNegativeSavingsWhenTheTargetExceedsTheSource() {
    // A 20 MB clip "targeted" at 500 MB must not claim a negative saving.
    let m = meta(fileSize: 20_000_000, seconds: 30)
    let e = SavingsEstimator.estimate(for: m, plan: CompressionPlan.plan(for: m, target: .mb500))
    // Since QA B1 the target is only a ceiling: the plan shrinks from the source.
    #expect(e.savedBytes >= 0)
    #expect(e.estimatedBytes < m.fileSize)
}

@Test func tinyGainsAreNotWorthwhile() {
    let m = meta(fileSize: 210_000_000, seconds: 600)
    // A plan that lands at ~205 MB: a couple of percent.
    let plan = CompressionPlan(width: 1920, height: 1080, frameRate: 30,
                               videoBitrate: 2_637_000, audioBitrate: 96_000, durationSeconds: 600)
    let e = SavingsEstimator.estimate(for: m, plan: plan)
    #expect(!e.isWorthwhile, "a few percent is not worth the battery")
}

@Test func zeroSizedInputDoesNotDivideByZero() {
    let m = meta(fileSize: 0)
    let e = SavingsEstimator.estimate(for: m, plan: CompressionPlan.plan(for: m, target: .mb200))
    #expect(e.savedFraction == 0)
    #expect(e.savedBytes == 0)
}

@Test func formatsTheSavingForDisplay() {
    let m = meta(fileSize: 1_800_000_000)
    let e = SavingsEstimator.estimate(for: m, plan: CompressionPlan.plan(for: m, target: .mb200))
    #expect(e.formattedSaving.contains("Saves"))
    #expect(SavingsEstimate(estimatedBytes: 10, savedBytes: 0, savedFraction: 0,
                            isWorthwhile: false).formattedSaving == "No saving")
}
