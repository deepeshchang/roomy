import Testing
@testable import VideoCompressor

// Regression: submitting a BGContinuedProcessingTaskRequest without a matching
// registration raised an uncatchable Objective-C assertion and killed the app
// the moment "Compress" was tapped. If that returns, this test crashes the run.
@MainActor
@Test func startingAndFinishingABatchDoesNotCrash() {
    let runner = BackgroundRunner.shared
    runner.begin(total: 3)
    runner.report(done: 1, current: 0.5)
    runner.begin(total: 2)   // a second batch must register a fresh identifier
    runner.finish(success: true)
}
