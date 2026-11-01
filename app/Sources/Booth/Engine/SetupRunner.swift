import BoothCore
import Foundation

/// First-run setup (SPEC §2.3): installs the managed engine when no valid one was found (or
/// updates it when it is older than the engine bundled with Booth), then runs
/// `<engine> setup --events` to download models. Both phases are reported as one `.setup`
/// progress stream, then `.done` once `app-info` says the engine is ready, or `.error`
/// (`setup_failed`).
///
/// It never installs when the last search stopped at an engine that didn't answer: that engine
/// exists (macOS may be holding it at a folder prompt), and a ~600 MB install would bury it. It
/// asks that engine again instead, which is what Try again after that failure needs. A Mac
/// without ffmpeg needs nothing more: the engine's setup downloads one along with the models.
@MainActor
final class SetupRunner: SetupRunning {
    private let locator: EngineLocator
    private let installer: ManagedEngineInstaller
    private var task: Task<Void, Never>?

    init(locator: EngineLocator, installer: ManagedEngineInstaller) {
        self.locator = locator
        self.installer = installer
    }

    func start(events: @escaping @MainActor (EngineEvent) -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let outcome: EngineEvent
            do {
                try await run(events: events)
                outcome = .done(EngineDone())
                Log.info("setup: done")
            } catch is CancellationError {
                Log.info("setup: cancelled")
                return
            } catch let error as JobError {
                Log.error("setup: \(error.message)")
                outcome = .error(JobError(code: .setupFailed, message: Formatting.errorBody(for: error)))
            } catch {
                Log.error("setup: \(error)")
                outcome = .error(JobError(code: .setupFailed, message: error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            task = nil
            events(outcome)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Private

    private func run(events: @escaping @MainActor (EngineEvent) -> Void) async throws {
        let executable: URL
        var combiner: SetupProgressCombiner

        if locator.installation == nil, let silent = locator.unresponsiveCandidate {
            Log.info("setup: \(silent.path) didn't answer; searching again")
            if case .ready = await locator.locate() { return }
            try Task.checkCancellation()
            if let silent = locator.unresponsiveCandidate {
                Log.error("setup: \(silent.path) still isn't answering; not creating the managed install")
                throw unresponsive(silent)
            }
        }

        if let existing = locator.installation?.executable {
            Log.info("setup: \(existing.path) needs models")
            executable = existing
            combiner = SetupProgressCombiner(installBytesExpected: 0, modelBytesTotal: 0)
        } else {
            await locator.toolchain.prepare()
            let missingTools = locator.toolchain.missingMediaTools
            if !missingTools.isEmpty {
                Log.info("setup: \(missingTools.joined(separator: ", ")) not found; the engine will download them")
            }
            Log.info(locator.managedInstallNeedsUpdate
                ? "setup: updating the managed install to the engine bundled with Booth"
                : "setup: no engine; creating the managed install")
            let installing = SetupProgressCombiner(installBytesExpected: SetupProgressCombiner.typicalEnvironmentBytes)
            events(.setup(installing.installing(bytesInstalled: 0, elapsed: 0)))
            let installed = try await installer.install { bytes, elapsed in
                events(.setup(installing.installing(bytesInstalled: bytes, elapsed: elapsed)))
            }
            try Task.checkCancellation()
            let info: EngineInfo
            switch await locator.probe(installed, source: .managedInstall) {
            case .valid(let answer):
                info = answer
            case .unresponsive:
                throw unresponsive(EngineCandidate(path: installed.path, source: .managedInstall))
            case .rejected:
                throw JobError(code: .setupFailed, message: "The engine was installed but doesn't start. Try again.")
            }
            let found = EngineInstallation(executable: installed, info: info)
            if case .ready = locator.adopt(found) { return }
            executable = installed
            combiner = installing
        }

        try await downloadModels(with: executable, combiner: &combiner, events: events)
        try Task.checkCancellation()
        switch await locator.refresh() {
        case .ready:
            return
        case .needsSetup(let installation):
            let missing = installation?.info.missing.joined(separator: ", ") ?? "the engine"
            throw JobError(code: .setupFailed, message: "Setup finished, but Booth is still missing \(missing). Try again.")
        case .unresponsive(let candidate):
            throw unresponsive(candidate)
        }
    }

    private func unresponsive(_ candidate: EngineCandidate) -> JobError {
        let folder = Formatting.engineFolder(executablePath: candidate.path, home: locator.toolchain.home.path)
        return JobError(code: .setupFailed, message: Formatting.engineUnresponsiveMessage(folder: folder))
    }

    /// `<engine> setup --events`, forwarding progress shifted past any install phase.
    private func downloadModels(
        with executable: URL, combiner: inout SetupProgressCombiner,
        events: @escaping @MainActor (EngineEvent) -> Void
    ) async throws {
        let process = EngineProcess(
            executable: executable, arguments: ["setup", "--events"], workingDirectory: nil,
            environment: locator.toolchain.environment, label: "setup")
        let state = CombinerBox(combiner)
        let result: (events: [EngineEvent], exit: EngineProcess.Exit)
        do {
            result = try await process.runToCompletion(onEvent: { event in
                if case .setup(let progress) = event {
                    events(.setup(state.combiner.downloading(progress)))
                }
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JobError(code: .setupFailed, message: "Booth couldn't start its engine: \(error.localizedDescription)")
        }
        combiner = state.combiner
        try Task.checkCancellation()

        for event in result.events.reversed() {
            switch event {
            case .done: return
            case .error(let error): throw error
            default: continue
            }
        }
        let exit = result.exit
        if exit.succeeded { return } // an older engine that ends without `done`; refresh() decides
        throw JobError(code: .setupFailed, message: EngineFailure.message(exitStatus: exit.status, signaled: exit.signaled, tail: exit.stderrTail))
    }
}

/// Lets the main-actor event callback update the combiner it shares with `downloadModels`.
@MainActor
private final class CombinerBox {
    var combiner: SetupProgressCombiner
    init(_ combiner: SetupProgressCombiner) { self.combiner = combiner }
}
