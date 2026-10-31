import BoothCore
import Foundation

/// Runs `booth enhance … --events` for each job (SPEC §1.6, §2.3).
///
/// Guarantees the `JobRunner` contract: every started job ends with exactly one `.done` or
/// `.error`, even when the engine crashes, is killed, or cannot be launched. A job that ends
/// without `.done` leaves nothing worth keeping, so its stems directory is deleted once the
/// engine process has exited (never while it may still be writing).
@MainActor
final class EngineJobRunner: JobRunner {
    private let locator: EngineLocator
    private var running: [Job.ID: RunningJob] = [:]
    /// Keeps the Mac awake while anything is in the booth.
    private var activity: NSObjectProtocol?

    private final class RunningJob {
        let process: EngineProcess
        let stems: URL
        let events: @MainActor (EngineEvent) -> Void
        var finished = false
        var succeeded = false
        var cancelRequested = false

        init(process: EngineProcess, stems: URL, events: @escaping @MainActor (EngineEvent) -> Void) {
            self.process = process
            self.stems = stems
            self.events = events
        }
    }

    /// SIGTERM → SIGKILL grace for a cancelled job (SPEC §2.3: three seconds).
    private let cancelGracePeriod: TimeInterval

    init(locator: EngineLocator, cancelGracePeriod: TimeInterval = 3) {
        self.locator = locator
        self.cancelGracePeriod = cancelGracePeriod
    }

    var runningJobIDs: [Job.ID] { Array(running.keys) }

    func start(job: Job, options: RunOptions, events: @escaping @MainActor (EngineEvent) -> Void) {
        guard running[job.id] == nil else {
            Log.error("job \(job.name) is already running")
            return
        }
        guard let executable = locator.installation?.executable else {
            failLater(events, JobError(code: .setupRequired, message: "Booth's engine isn't set up yet."))
            return
        }
        let stems = options.stemsDirectory
        do {
            try JobCache.prepare(stems)
        } catch {
            failLater(events, JobError(code: .internal, message: "Booth couldn't create its working folder: \(error.localizedDescription)"))
            return
        }

        let process = EngineProcess(
            executable: executable, arguments: options.arguments(input: job.input), workingDirectory: stems,
            environment: locator.toolchain.environment, label: "job \(job.name)")
        let entry = RunningJob(process: process, stems: stems, events: events)
        running[job.id] = entry
        do {
            try process.run(
                onEvent: { [weak self] event in self?.deliver(event, for: job.id) },
                onExit: { [weak self] exit in self?.processDidExit(exit, for: job.id) })
        } catch {
            running[job.id] = nil
            JobCache.removeInBackground(stems) // nothing ran in it
            failLater(events, JobError(code: .engineFailed, message: "Booth couldn't start its engine: \(error.localizedDescription)"))
            return
        }
        updateActivity()
    }

    func cancel(jobID: Job.ID) {
        guard let entry = running[jobID], !entry.cancelRequested else { return }
        entry.cancelRequested = true
        // The engine answers SIGTERM with its own `cancelled` error; processDidExit covers a
        // process that dies without one.
        entry.process.terminate(gracePeriod: cancelGracePeriod)
    }

    func cancelAll() {
        for (id, entry) in running {
            entry.cancelRequested = true
            entry.process.terminateAndWait(timeout: 1)
            finish(id, with: .error(JobError(code: .cancelled, message: "Cancelled.")))
        }
    }

    func pruneCache(in root: URL, protecting: Set<URL>) {
        // Running jobs are in use whatever the caller listed.
        JobCache.pruneInBackground(root: root, protecting: protecting.union(running.values.map(\.stems)))
    }

    // MARK: - Private

    private func deliver(_ event: EngineEvent, for id: Job.ID) {
        guard let entry = running[id], !entry.finished else { return }
        switch event {
        case .done, .error: finish(id, with: event)
        default: entry.events(event)
        }
    }

    /// Forwards the job's one terminal event.
    private func finish(_ id: Job.ID, with event: EngineEvent) {
        guard let entry = running[id], !entry.finished else { return }
        entry.finished = true
        if case .done = event { entry.succeeded = true }
        entry.events(event)
    }

    private func processDidExit(_ exit: EngineProcess.Exit, for id: Job.ID) {
        guard let entry = running.removeValue(forKey: id) else { return }
        defer {
            updateActivity()
            // Failed, cancelled or crashed: the engine is gone, and so is any use for its stems.
            if !entry.succeeded { JobCache.removeInBackground(entry.stems) }
        }
        guard !entry.finished else { return }
        let error: JobError
        if entry.cancelRequested {
            error = JobError(code: .cancelled, message: "Cancelled.")
        } else if exit.succeeded {
            error = JobError(code: .engineFailed, message: EngineFailure.silentExit)
        } else {
            error = JobError(code: .engineFailed, message: EngineFailure.message(exitStatus: exit.status, signaled: exit.signaled, tail: exit.stderrTail))
            Log.error("engine failed without an error event; stderr tail:\n\(exit.stderrTail.text)")
        }
        entry.finished = true
        entry.events(.error(error))
    }

    /// Reports a failure on the next main-queue turn, so `start` never calls back re-entrantly.
    private func failLater(_ events: @escaping @MainActor (EngineEvent) -> Void, _ error: JobError) {
        Log.error("job could not start: \(error.message)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated { events(.error(error)) }
        }
    }

    private func updateActivity() {
        if running.isEmpty, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        } else if !running.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Enhancing audio")
        }
    }
}
