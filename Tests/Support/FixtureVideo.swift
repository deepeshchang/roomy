import AVFoundation
import CoreGraphics
import Foundation

/// Generates small, real .mov files so tests never need checked-in binaries.
enum FixtureVideo {
    static func make(seconds: Double, size: CGSize) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes)

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let frames = max(1, Int(seconds * Double(fps)))

        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw FixtureError.noPixelBufferPool
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw FixtureError.noPixelBufferPool }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                // Noise, so the source has a realistic bitrate and the batch
                // has something to save. Flat grey frames are "already small"
                // since the never-grow rule (QA B1) and would be skipped.
                let byteCount = CVPixelBufferGetBytesPerRow(buffer)
                    * CVPixelBufferGetHeight(buffer)
                arc4random_buf(base, byteCount)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            adaptor.append(buffer,
                           withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                        timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? FixtureError.writeFailed
        }
        return url
    }

    /// A fixture with a real audio track, to prove audio survives transcoding.
    static func makeWithAudio(seconds: Double) async throws -> URL {
        let silent = try await make(seconds: seconds, size: CGSize(width: 320, height: 240))
        defer { try? FileManager.default.removeItem(at: silent) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-av-\(UUID().uuidString).mov")

        let composition = AVMutableComposition()
        let source = AVURLAsset(url: silent)
        let duration = try await source.load(.duration)

        if let videoTrack = try await source.loadTracks(withMediaType: .video).first,
           let target = composition.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) {
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       of: videoTrack, at: .zero)
        }

        // A tone track written as 16-bit PCM, then muxed in.
        let audioURL = try makeTone(seconds: seconds)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let toneAsset = AVURLAsset(url: audioURL)
        if let toneTrack = try await toneAsset.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) {
            let toneDuration = try await toneAsset.load(.duration)
            try target.insertTimeRange(CMTimeRange(start: .zero,
                                                   duration: min(duration, toneDuration)),
                                       of: toneTrack, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetPassthrough) else {
            throw FixtureError.writeFailed
        }
        try await export.export(to: url, as: .mov)
        return url
    }

    private static func makeTone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(44_100 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw FixtureError.writeFailed
        }
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frames) {
                channel[frame] = sin(2 * .pi * 440 * Float(frame) / 44_100) * 0.2
            }
        }
        try file.write(from: buffer)
        return url
    }

    enum FixtureError: Error {
        case noPixelBufferPool
        case writeFailed
    }
}
