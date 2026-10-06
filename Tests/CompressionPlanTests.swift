import Testing
@testable import VideoCompressor

private func video(_ w: Int, _ h: Int, seconds: Double, fps: Double = 30,
                   sizeMB: Int = 1800) -> VideoMetadata {
    VideoMetadata(filename: "x.mov", fileSize: Int64(sizeMB) * 1_000_000,
                  duration: seconds, width: w, height: h, frameRate: fps,
                  codec: "h264", bitrate: 0)
}

@Test func hitsTheTargetForATypicalClip() {
    // 10 min 1080p, aiming for 200 MB.
    let plan = CompressionPlan.plan(for: video(1920, 1080, seconds: 600), target: .mb200)
    let mb = Double(plan.estimatedBytes) / 1_000_000
    #expect(mb > 180 && mb <= 205, "estimated \(mb) MB should land near the 200 MB target")
}

@Test func fourKIsAlwaysCappedAt1080p() {
    let plan = CompressionPlan.plan(for: video(3840, 2160, seconds: 120), target: .mb500)
    #expect(max(plan.width, plan.height) <= 1920)
    #expect(plan.width == 1920 && plan.height == 1080)
}

@Test func sixtyFpsIsHalvedButSlowMotionIsNot() {
    #expect(CompressionPlan.plan(for: video(1920, 1080, seconds: 60, fps: 60),
                                 target: .mb200).frameRate == 30)
    #expect(CompressionPlan.plan(for: video(1920, 1080, seconds: 60, fps: 30),
                                 target: .mb200).frameRate == 30)
    // 240fps slow motion keeps its frame rate or the effect is destroyed.
    #expect(CompressionPlan.plan(for: video(1920, 1080, seconds: 60, fps: 240),
                                 target: .mb200).frameRate == 240)
}

@Test func aTightTargetOnALongVideoStepsResolutionDown() {
    // 1 hour into 100 MB cannot be done at 1080p, so the frame must shrink.
    let plan = CompressionPlan.plan(for: video(1920, 1080, seconds: 3600), target: .mb100)
    #expect(max(plan.width, plan.height) < 1920, "expected a smaller frame, got \(plan.width)x\(plan.height)")
}

@Test func aGenerousTargetOnAShortVideoKeepsFullResolution() {
    let plan = CompressionPlan.plan(for: video(1920, 1080, seconds: 30), target: .mb500)
    #expect(plan.width == 1920 && plan.height == 1080)
}

@Test func neverUpscalesASmallSource() {
    let plan = CompressionPlan.plan(for: video(640, 480, seconds: 60), target: .mb500)
    #expect(plan.width <= 640 && plan.height <= 480)
}

@Test func portraitAspectRatioIsPreserved() {
    let plan = CompressionPlan.plan(for: video(1080, 1920, seconds: 600), target: .mb200)
    #expect(plan.width < plan.height, "portrait must stay portrait")
    let sourceAspect = 1080.0 / 1920.0
    let planAspect = Double(plan.width) / Double(plan.height)
    #expect(abs(sourceAspect - planAspect) < 0.02)
}

@Test func dimensionsAreAlwaysEven() {
    for (w, h) in [(1080, 1921), (999, 555), (1442, 1079)] {
        let plan = CompressionPlan.plan(for: video(w, h, seconds: 120), target: .mb200)
        #expect(plan.width % 2 == 0, "\(plan.width) must be even for HEVC")
        #expect(plan.height % 2 == 0, "\(plan.height) must be even for HEVC")
    }
}

@Test func bitrateNeverCollapsesBelowTheFloor() {
    // 3 hours into 50 MB is impossible; the plan must stay encodable and say so
    // honestly by estimating bigger than the target.
    let plan = CompressionPlan.plan(for: video(1920, 1080, seconds: 10_800), target: .mb50)
    #expect(plan.videoBitrate >= CompressionPlan.minimumVideoBitrate)
    #expect(plan.estimatedBytes > plan_target_bytes, "must not promise the impossible")
}
private let plan_target_bytes = TargetSize.mb50.bytes

@Test func zeroDurationDoesNotDivideByZero() {
    let plan = CompressionPlan.plan(for: video(1920, 1080, seconds: 0), target: .mb200)
    #expect(plan.videoBitrate > 0)
    #expect(plan.width > 0 && plan.height > 0)
}

@Test func aShortClipWithAGenerousTargetGetsASaneBitrate() {
    // Regression: a 1 s clip aimed at 200 MB produced a 1.6 Gbps bitrate and
    // the hardware encoder rejected every frame.
    let plan = CompressionPlan.plan(for: video(320, 240, seconds: 1), target: .mb200)
    #expect(plan.videoBitrate <= CompressionPlan.maximumVideoBitrate)
    let ceiling = Double(plan.width * plan.height * plan.frameRate)
        * CompressionPlan.maxBitsPerPixelPerFrame
    #expect(Double(plan.videoBitrate) <= ceiling + 1)
}

@Test func theBitrateCeilingScalesWithResolution() {
    let small = CompressionPlan.plan(for: video(640, 480, seconds: 2), target: .mb500)
    let large = CompressionPlan.plan(for: video(1920, 1080, seconds: 2), target: .mb500)
    #expect(small.videoBitrate < large.videoBitrate)
}
