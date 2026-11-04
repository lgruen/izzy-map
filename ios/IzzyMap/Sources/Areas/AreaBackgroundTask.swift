import BackgroundTasks
import Foundation
import os

/// The system's progress UI for an area download, and the time to finish it
/// in the background: one `BGContinuedProcessingTask` (iOS 26, supported
/// API) per run of the download queue, submitted when she taps Download or
/// Resume (a continued-processing request must come from the foreground app).
///
/// - Identifiers use the wildcard form the header asks for: Info.plist's
///   `BGTaskSchedulerPermittedIdentifiers` lists
///   `org.gruenschloss.izzymap.areas.*`, each request is
///   `org.gruenschloss.izzymap.areas.<n>`. Continued-processing handlers may
///   be registered after launch, but only once per identifier, hence a new
///   suffix per run.
/// - Strategy `.fail`: if the system can't run it now the download still
///   runs while IzzyMap is in the foreground (and stops resumably when iOS
///   suspends it) — never a queued task that starts after the work is done.
/// - The download itself never waits for the task: it starts at once, and
///   the task adopts its progress when it starts.
/// - Expiration (the system or she ends it from the Live Activity): the
///   store stops the download — the tiles so far are journalled — and the
///   task completes.
@MainActor
final class AreaBackgroundTask {
    static let identifierPrefix = "org.gruenschloss.izzymap.areas"

    /// Called when the system expires the running task.
    var onExpire: (() -> Void)?

    private var task: BGContinuedProcessingTask?
    private var awaitingID: String?
    private var counter = 0
    private var latest: (done: Int64, total: Int64, title: String, subtitle: String) = (0, 1, "", "")
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "Areas")

    var isRunning: Bool { task != nil || awaitingID != nil }

    /// Submits a request; false when the system refused it (the download
    /// then runs in the foreground only).
    @discardableResult
    func begin(title: String, subtitle: String) -> Bool {
        guard !isRunning else { return true }
        #if DEBUG
        // UI tests and screenshots: no system task (its banner would cover the app)
        if UserDefaults.standard.bool(forKey: "noAreaBackgroundTask") { return false }
        #endif
        counter += 1
        let id = "\(Self.identifierPrefix).\(Int(Date.now.timeIntervalSince1970))\(counter)"
        latest.title = title
        latest.subtitle = subtitle
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask, self.awaitingID == id else {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.started(task)
            }
        }
        guard registered else {
            Self.logger.error("area task \(id, privacy: .public) not registered (Info.plist identifiers?)")
            return false
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
        request.strategy = .fail
        // iOS 27: submitTaskRequest reports every refusal through its handler
        // (the old throwing submit is deprecated). Until it answers, the task
        // counts as awaited; a refusal clears that and the download simply
        // runs in the foreground.
        awaitingID = id
        BGTaskScheduler.shared.submitTaskRequest(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                Self.logger.notice("area task not submitted: \(error.localizedDescription, privacy: .public)")
                if self?.awaitingID == id { self?.awaitingID = nil }
            }
        }
        return true
    }

    private func started(_ task: BGContinuedProcessingTask) {
        awaitingID = nil
        self.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
        apply()
    }

    /// Progress in tiles, and the lines the system shows.
    func update(done: Int, total: Int, title: String, subtitle: String) {
        latest = (Int64(done), Int64(max(total, done, 1)), title, subtitle)
        apply()
    }

    private func apply() {
        guard let task else { return }
        task.progress.totalUnitCount = latest.total
        task.progress.completedUnitCount = min(latest.done, latest.total)
        if task.title != latest.title || task.subtitle != latest.subtitle {
            task.updateTitle(latest.title, subtitle: latest.subtitle)
        }
    }

    /// The queue is empty (or stopped): the task ends — at 100 % when
    /// everything asked for arrived (a Pause or Delete is no failure).
    func end(success: Bool) {
        awaitingID = nil
        guard let task else { return }
        self.task = nil
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task.setTaskCompleted(success: success)
    }

    private func expired() {
        Self.logger.notice("area task expired: stopping the download")
        onExpire?()
        end(success: false)
    }
}
