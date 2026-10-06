import BackgroundTasks
import Foundation

/// Keeps a batch running after the user leaves the app.
///
/// Uses `BGContinuedProcessingTask` (iOS 26+): work the user started, which the
/// system lets continue in the background and shows as a progress indicator.
/// On older iOS, or if the system refuses the request, the batch simply runs
/// while the app is open.
@MainActor
final class BackgroundRunner {
    static let shared = BackgroundRunner()
    static let identifierPrefix = "com.deepeshchang.VideoCompressor.batch"

    /// Called when iOS reclaims the background time; the batch should stop
    /// cleanly so the current video is not left half-written.
    var onExpire: (() -> Void)?

    private var task: AnyObject?   // BGContinuedProcessingTask, iOS 26+
    private var total = 0

    func begin(total: Int) {
        self.total = total
        guard #available(iOS 26.0, *) else { return }
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"

        // Register this exact identifier, then submit — and ONLY submit if
        // registration succeeded. Submitting an unregistered request raises an
        // Objective-C assertion inside BGTaskScheduler that Swift cannot
        // catch; that is what crashed on "Compress". Continued-processing
        // tasks are exempt from the register-before-launch rule, and the UUID
        // makes each identifier unique, so it is never registered twice (a
        // second registration of one identifier is also fatal).
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier,
                                                         using: .main) { task in
            MainActor.assumeIsolated {
                BackgroundRunner.shared.attach(task)
            }
        }
        guard registered else { return }   // batch still runs in the foreground

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Compressing",
            subtitle: "0 of \(total) done")
        request.strategy = .fail   // start now or not at all; the batch runs either way
        try? BGTaskScheduler.shared.submit(request)
    }

    /// - Parameters:
    ///   - done: videos fully finished.
    ///   - current: progress (0...1) of the video in flight.
    func report(done: Int, current: Double) {
        guard #available(iOS 26.0, *),
              let task = task as? BGContinuedProcessingTask else { return }
        // Per-mille units so progress moves during a long single export —
        // the system may end a continued task that stops reporting progress.
        task.progress.totalUnitCount = Int64(max(total, 1) * 1000)
        task.progress.completedUnitCount = Int64(done * 1000) + Int64(current * 1000)
        task.updateTitle("Compressing", subtitle: "\(done) of \(total) done")
    }

    func finish(success: Bool) {
        if #available(iOS 26.0, *), let task = task as? BGTask {
            task.setTaskCompleted(success: success)
        }
        task = nil
    }

    private func attach(_ task: BGTask) {
        guard #available(iOS 26.0, *), task is BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        self.task = task
        task.expirationHandler = {
            Task { @MainActor in BackgroundRunner.shared.onExpire?() }
        }
    }
}
