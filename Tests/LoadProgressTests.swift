import Testing
@testable import VideoCompressor

@Test func progressCombinesVideoAndPhotoStreams() {
    var p = LoadProgress()
    p.videos = (scanned: 100, total: 300)
    p.photos = (scanned: 140, total: 700)
    #expect(p.scanned == 240)
    #expect(p.total == 1000)
    #expect(abs(p.fraction - 0.24) < 0.0001)
    #expect(p.label == "Reading sizes… \(240.formatted()) of \(1000.formatted())")
}

@Test func progressBeforeAnyTotalIsIndeterminateLabel() {
    let p = LoadProgress()
    #expect(p.fraction == 0)
    #expect(p.label == "Reading sizes…")
}

@Test func progressFractionIsClamped() {
    var p = LoadProgress()
    p.videos = (scanned: 12, total: 10)
    #expect(p.fraction == 1)
}

@Test func progressShowsOnlyAfterDelay() {
    #expect(!LoadProgress.shouldShow(elapsed: 0.1))
    #expect(!LoadProgress.shouldShow(elapsed: 0.299))
    #expect(LoadProgress.shouldShow(elapsed: 0.3))
}

@Test func staleLoadGenerationIsRejected() {
    var g = LoadGeneration()
    let first = g.begin()
    #expect(g.isCurrent(first))
    let second = g.begin()
    #expect(!g.isCurrent(first))
    #expect(g.isCurrent(second))
}
