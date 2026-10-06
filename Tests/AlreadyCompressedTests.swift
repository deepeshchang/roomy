import Testing
import Foundation
@testable import VideoCompressor

/// A 60 s clip at the given resolution and bitrate (megabits per second).
private func clip(_ id: String, _ w: Int, _ h: Int, mbps: Double) -> LibraryVideo {
    LibraryVideo(id: id, filename: "\(id).MOV",
                 fileSize: Int64(mbps * 1_000_000 / 8 * 60),
                 duration: 60, creationDate: nil, width: w, height: h)
}

private func freshLedger() -> CompressionLedger {
    let suite = "test.ledger.\(UUID().uuidString)"
    return CompressionLedger(defaults: UserDefaults(suiteName: suite)!)
}

@Test func typicalIPhoneH264IsACandidate() {
    #expect(!clip("a", 1920, 1080, mbps: 17).looksAlreadyCompressed)   // 1080p30 H.264
    #expect(!clip("b", 3840, 2160, mbps: 45).looksAlreadyCompressed)   // 4K30 H.264
    #expect(!clip("c", 1920, 1080, mbps: 25).looksAlreadyCompressed)   // 1080p60 H.264
}

@Test func typicalHEVCIsTreatedAsAlreadyCompressed() {
    #expect(clip("a", 1920, 1080, mbps: 6).looksAlreadyCompressed)     // 1080p30 HEVC
    #expect(clip("b", 3840, 2160, mbps: 25).looksAlreadyCompressed)    // 4K30 HEVC
}

@Test func degenerateVideosAreNeverHiddenByTheHeuristic() {
    // Missing size or duration must not make a video vanish from the list.
    let noDuration = LibraryVideo(id: "x", filename: "x", fileSize: 1_000, duration: 0,
                                  creationDate: nil, width: 1920, height: 1080)
    let noPixels = LibraryVideo(id: "y", filename: "y", fileSize: 1_000, duration: 10,
                                creationDate: nil, width: 0, height: 0)
    #expect(!noDuration.looksAlreadyCompressed)
    #expect(!noPixels.looksAlreadyCompressed)
}

@Test func ledgerRemembersBothSidesOfASave() {
    let ledger = freshLedger()
    #expect(ledger.handledIDs.isEmpty)

    ledger.record(original: "orig-1", compressed: "new-1")
    #expect(ledger.handledIDs == ["orig-1", "new-1"])

    ledger.record(original: "orig-2", compressed: nil)   // save gave no new ID
    #expect(ledger.handledIDs == ["orig-1", "new-1", "orig-2"])
}

@Test func ledgerPersistsAcrossInstances() {
    let suite = "test.ledger.\(UUID().uuidString)"
    CompressionLedger(defaults: UserDefaults(suiteName: suite)!)
        .record(original: "o", compressed: "n")
    let reopened = CompressionLedger(defaults: UserDefaults(suiteName: suite)!)
    #expect(reopened.handledIDs == ["o", "n"], "must survive an app relaunch")
}

@Test func candidatesDropHandledAndEfficientVideosButKeepOrder() {
    let videos = [
        clip("big-h264", 3840, 2160, mbps: 45),
        clip("handled", 1920, 1080, mbps: 17),
        clip("hevc", 1920, 1080, mbps: 6),
        clip("small-h264", 1920, 1080, mbps: 17),
    ]
    let result = LibraryVideo.candidates(videos, handled: ["handled"])
    #expect(result.map(\.id) == ["big-h264", "small-h264"],
            "largest-first order must survive filtering")
}
