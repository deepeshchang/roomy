import AVFoundation
import Foundation

enum CompressionError: Error, LocalizedError {
    case unsupportedSource
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedSource: "This video can't be read."
        case .exportFailed(let why): "Compression failed: \(why)"
        case .cancelled: "Compression was cancelled."
        }
    }
}

/// Re-encodes a video to an explicit bitrate, resolution and frame rate.
///
/// Built on AVAssetReader/AVAssetWriter rather than AVAssetExportSession
/// because the presets choose their own bitrate and ignore a size budget —
/// which is why 1.8 GB clips were still landing at 700 MB.
///
/// `nonisolated` on purpose: AVFoundation calls its pull callbacks on our own
/// queues, and an inherited actor isolation on those closures is exactly what
/// crashed this app once already. Nothing here touches the main actor.
struct VideoCompressorEngine: Sendable {

    static var workingDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compressed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func compress(asset box: AVAssetBox,
                  basename: String,
                  plan: CompressionPlan,
                  metadata: MetadataBox? = nil,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = box.asset
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw CompressionError.unsupportedSource }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        let output = Self.workingDirectory.appendingPathComponent(
            "\(basename)-hevc-\(UUID().uuidString).mov")

        // --- Reader -------------------------------------------------------
        let reader = try AVAssetReader(asset: asset)

        // A video composition does the scaling, the orientation fix and the
        // frame-rate change in one step. Doing it by hand means portrait clips
        // come out sideways.
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.renderSize = CGSize(width: plan.width, height: plan.height)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.frameRate))

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw CompressionError.unsupportedSource }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); audioOutput = out }
        }

        // --- Writer -------------------------------------------------------
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        if let metadata { writer.metadata = metadata.items }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: plan.frameRate * 2,
                AVVideoExpectedSourceFrameRateKey: plan.frameRate,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw CompressionError.unsupportedSource }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: plan.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        guard reader.startReading() else {
            throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "could not read the video")
        }
        guard writer.startWriting() else {
            throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "could not write the file")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            // Video and audio MUST be fed concurrently. With more than one
            // input, AVAssetWriter enforces interleaving: it stops accepting
            // video until audio catches up. Feeding video to completion first
            // therefore deadlocks — video waits for audio, audio waits for
            // video to finish. Short clips escape only because they fit in the
            // writer's buffer, which is why this hid behind passing tests.
            let videoQueue = DispatchQueue(label: "VideoCompressor.video")
            let audioQueue = DispatchQueue(label: "VideoCompressor.audio")
            // The pumps run on dispatch queues, outside this task, so
            // Task.isCancelled inside them is always false. Cancellation has
            // to be pushed in: cancelling the reader makes both outputs run
            // dry, the pumps finish, and the check after the group turns that
            // into a clean cancel instead of a silently truncated "success".
            struct ReaderBox: @unchecked Sendable { let reader: AVAssetReader }
            // Each input/output pair is touched only by its own pump on its
            // own serial queue, so handing them to child tasks is safe.
            struct Lane: @unchecked Sendable {
                let input: AVAssetWriterInput
                let output: AVAssetReaderOutput
            }
            let videoLane = Lane(input: videoInput, output: videoOutput)
            let audioLane = audioInput.flatMap { i in audioOutput.map { Lane(input: i, output: $0) } }
            let readerBox = ReaderBox(reader: reader)
            try await withTaskCancellationHandler {
              try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await pump(input: videoLane.input, from: videoLane.output, on: videoQueue) { time in
                        guard duration > 0 else { return }
                        onProgress(min(0.99, time / duration))
                    }
                }
                if let audioLane {
                    group.addTask {
                        try await pump(input: audioLane.input, from: audioLane.output, on: audioQueue) { _ in }
                    }
                }
                try await group.waitForAll()
              }
            } onCancel: {
                readerBox.reader.cancelReading()
            }
            try Task.checkCancellation()
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw CompressionError.cancelled }
            throw error
        }

        await writer.finishWriting()

        if writer.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.exportFailed(
                writer.error?.localizedDescription ?? "the file could not be finished")
        }
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.exportFailed(
                reader.error?.localizedDescription ?? "the video could not be read")
        }

        onProgress(1.0)
        return output
    }

    /// Feed one writer input from one reader output until the source runs dry.
    private func pump(input: AVAssetWriterInput,
                      from output: AVAssetReaderOutput,
                      on queue: DispatchQueue,
                      onTime: @escaping @Sendable (Double) -> Void) async throws {
        final class Guard: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let once = Guard()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        if once.claim() { continuation.resume(throwing: CancellationError()) }
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if once.claim() { continuation.resume() }
                        return
                    }
                    let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !input.append(sample) {
                        if once.claim() {
                            continuation.resume(throwing: CompressionError.exportFailed(
                                "the encoder rejected a frame"))
                        }
                        return
                    }
                    onTime(time)
                }
            }
        }
    }
}
