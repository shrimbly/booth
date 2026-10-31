import AppKit
import BoothCore
import Foundation

/// Re-saves a finished job at a new mix: `booth remix <stems> -s S -b B -m M --events`
/// (SPEC §1.5), which rewrites the job's outputs in place from its preview stems.
@MainActor
final class EngineRemixer: Remixing {
    private let locator: EngineLocator
    private var inFlight: [ObjectIdentifier: EngineProcess] = [:]
    private var terminationObserver: NSObjectProtocol?

    init(locator: EngineLocator) {
        self.locator = locator
        // A remix is short, but must not outlive the app.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    func remix(_ result: JobResult, to mix: Mix) async throws -> EngineDone {
        guard let stems = result.stems,
              FileManager.default.fileExists(atPath: stems.appendingPathComponent(StemsManifest.fileName).path) else {
            throw JobError(code: .internal, message: "This file's stems are gone, so its mix can't change. Enhance it again to remix it.")
        }
        guard let executable = locator.installation?.executable else {
            throw JobError(code: .setupRequired, message: "Booth's engine isn't set up yet.")
        }
        let arguments = [
            "remix", stems.path,
            "-s", String(mix.speech), "-b", String(mix.background), "-m", String(mix.music),
            "--events",
        ]
        let process = EngineProcess(
            executable: executable, arguments: arguments, workingDirectory: stems,
            environment: locator.toolchain.environment, label: "remix \(result.output.lastPathComponent)")
        let key = ObjectIdentifier(process)
        inFlight[key] = process
        defer { inFlight[key] = nil }

        let outcome: (events: [EngineEvent], exit: EngineProcess.Exit)
        do {
            outcome = try await process.runToCompletion()
        } catch {
            throw JobError(code: .engineFailed, message: "Booth couldn't start its engine: \(error.localizedDescription)")
        }
        for event in outcome.events.reversed() {
            switch event {
            case .done(let done): return done
            case .error(let error): throw error
            default: continue
            }
        }
        let exit = outcome.exit
        if exit.wasTerminated { throw JobError(code: .cancelled, message: "Cancelled.") }
        if exit.succeeded { throw JobError(code: .engineFailed, message: EngineFailure.silentExit) }
        throw JobError(code: .engineFailed, message: EngineFailure.message(exitStatus: exit.status, signaled: exit.signaled, tail: exit.stderrTail))
    }

    private func terminateAll() {
        for process in inFlight.values { process.terminateAndWait(timeout: 1) }
    }
}
