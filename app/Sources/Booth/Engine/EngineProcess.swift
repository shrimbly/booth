import BoothCore
import Foundation

/// One run of the engine executable (or of `uv`, which shares the plumbing).
///
/// - stdout is read as JSON Lines; every decoded event is delivered on the main queue, in order.
///   Lines that are not events are logged and otherwise ignored.
/// - stderr goes to the log line by line, and its tail is kept to explain a crash.
/// - `onExit` arrives on the main queue after the last event.
///
/// The engine puts itself in its own process group in `--events` mode, so `terminate` signals
/// the whole group (the engine and its ffmpeg/demucs children), falling back to the single
/// process while the group does not exist yet.
final class EngineProcess: @unchecked Sendable {
    struct Exit: Sendable {
        /// The exit status, or the signal number when `signaled`.
        var status: Int32
        var signaled: Bool
        var stderrTail: OutputTail
        /// `terminate()` was called before the process ended.
        var wasTerminated: Bool
        /// `runToCompletion`'s own `timeout` ended it (a no-answer, not a crash).
        var timedOut = false

        var succeeded: Bool { !signaled && status == 0 }
    }

    let executable: URL
    let arguments: [String]
    /// Prefix for log lines, e.g. `"job interview.mp4"`.
    let label: String

    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var stdoutBuffer = LineBuffer()
    private var stderrBuffer = LineBuffer()
    private var tail = OutputTail()
    private var terminationRequested = false
    private var timeoutFired = false

    /// How long to wait for the pipes to drain after the process exits. A grandchild that
    /// inherited stderr can hold it open indefinitely.
    private static let drainTimeout: TimeInterval = 2

    init(executable: URL, arguments: [String], workingDirectory: URL?, environment: [String: String], label: String) {
        self.executable = executable
        self.arguments = arguments
        self.label = label
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var processIdentifier: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// The command line as a shell would need it, for the log.
    var commandLine: String {
        ([executable.path] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    /// Launches the process. Throws when it cannot be started at all; after that, everything
    /// is reported through the callbacks.
    func run(
        onEvent: @escaping @MainActor (EngineEvent) -> Void,
        onExit: @escaping @MainActor (Exit) -> Void
    ) throws {
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stderrDrained = DispatchSemaphore(value: 0)

        stdout.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if let last = lock.withLock({ stdoutBuffer.finish() }) { handleStdoutLine(last, onEvent: onEvent) }
                stdoutDrained.signal()
                return
            }
            for line in lock.withLock({ stdoutBuffer.append(chunk) }) { handleStdoutLine(line, onEvent: onEvent) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if let last = lock.withLock({ stderrBuffer.finish() }) { handleStderrLine(last) }
                stderrDrained.signal()
                return
            }
            for line in lock.withLock({ stderrBuffer.append(chunk) }) { handleStderrLine(line) }
        }

        process.terminationHandler = { [self] finished in
            // Events are dispatched to the main queue as they are read, so once stdout has
            // drained, an exit dispatched now lands after the last event.
            let drainDeadline = DispatchTime.now() + Self.drainTimeout
            if stdoutDrained.wait(timeout: drainDeadline) == .timedOut {
                Log.error("\(label): stdout still open \(Self.drainTimeout) s after exit")
            }
            _ = stderrDrained.wait(timeout: drainDeadline)
            let exit = lock.withLock {
                Exit(
                    status: finished.terminationStatus,
                    signaled: finished.terminationReason == .uncaughtSignal,
                    stderrTail: tail,
                    wasTerminated: terminationRequested,
                    timedOut: timeoutFired)
            }
            let description = exit.signaled ? "signal \(exit.status)" : "status \(exit.status)"
            Log.info("\(label): exited with \(description)\(exit.wasTerminated ? " after terminate" : "")")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onExit(exit) }
            }
        }

        Log.info("\(label): \(commandLine)")
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            Log.error("\(label): could not start \(executable.path): \(error.localizedDescription)")
            throw error
        }
        Log.info("\(label): pid \(process.processIdentifier)")
    }

    /// SIGTERM to the process group now, SIGKILL after `gracePeriod` if anything is left.
    /// Safe to call more than once and after the process has ended.
    func terminate(gracePeriod: TimeInterval = 3) {
        guard beginTermination() else { return }
        send(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) { [self] in
            guard process.isRunning || groupIsAlive else { return }
            Log.error("\(label): still running \(gracePeriod) s after SIGTERM; sending SIGKILL")
            send(SIGKILL)
        }
    }

    /// Quitting: SIGTERM, wait up to `timeout` for the process to end, then SIGKILL whatever is
    /// left. Blocks the caller for at most `timeout`.
    func terminateAndWait(timeout: TimeInterval) {
        guard beginTermination() else { return }
        send(SIGTERM)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning || groupIsAlive {
            Log.error("\(label): still running at quit; sending SIGKILL")
            send(SIGKILL)
        }
    }

    // MARK: - Private

    /// Records the request; false when there is nothing (left) to terminate.
    private func beginTermination() -> Bool {
        guard process.processIdentifier > 0 else { return false }
        let first = lock.withLock {
            defer { terminationRequested = true }
            return !terminationRequested
        }
        if !process.isRunning && !groupIsAlive { return false }
        if first { Log.info("\(label): terminating pid \(process.processIdentifier)") }
        return true
    }

    /// Marks the coming termination as a timeout, so `Exit.timedOut` tells it from a crash.
    fileprivate func markTimedOut() {
        lock.withLock { timeoutFired = true }
    }

    /// The engine's process group still has members (children can outlive the engine).
    private var groupIsAlive: Bool {
        let pid = process.processIdentifier
        return pid > 0 && kill(-pid, 0) == 0
    }

    private func send(_ signalNumber: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // The group exists once the engine has called setpgrp(); before that, signal it alone.
        if kill(-pid, signalNumber) != 0 && process.isRunning {
            kill(pid, signalNumber)
        }
    }

    private func handleStdoutLine(_ line: String, onEvent: @escaping @MainActor (EngineEvent) -> Void) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Log.info("\(label) ← \(line)")
        guard let event = EngineEventDecoder.decode(line: line) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onEvent(event) }
        }
    }

    private func handleStderrLine(_ line: String) {
        guard let stored = lock.withLock({ tail.append(line) }) else { return }
        Log.info("\(label) stderr: \(stored)")
    }

    private static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
        if !argument.isEmpty && argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Events gathered by `runToCompletion`, appended on the main actor.
@MainActor
private final class EventLog {
    var events: [EngineEvent] = []
    var exited = false
}

extension EngineProcess {
    /// Runs to the end and returns every event plus the exit, terminating the process if the
    /// calling task is cancelled or `timeout` passes (then `Exit.timedOut` is true).
    ///
    /// `onSlow` fires once when `slowAfter` passes and the process is still running. It does
    /// not stop the process: the caller can say it is still waiting.
    @MainActor
    func runToCompletion(
        timeout: TimeInterval? = nil,
        slowAfter: TimeInterval? = nil,
        onSlow: (@MainActor () -> Void)? = nil,
        onEvent: @escaping @MainActor (EngineEvent) -> Void = { _ in }
    ) async throws -> (events: [EngineEvent], exit: Exit) {
        let collected = EventLog()
        var timers: [DispatchWorkItem] = []
        defer { timers.forEach { $0.cancel() } }
        return try await withTaskCancellationHandler {
            let exit: Exit = try await withCheckedThrowingContinuation { continuation in
                do {
                    try run(onEvent: { event in
                        collected.events.append(event)
                        onEvent(event)
                    }, onExit: { exit in
                        collected.exited = true
                        continuation.resume(returning: exit)
                    })
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let slowAfter, let onSlow {
                    let item = DispatchWorkItem {
                        MainActor.assumeIsolated {
                            guard !collected.exited else { return }
                            onSlow()
                        }
                    }
                    timers.append(item)
                    DispatchQueue.main.asyncAfter(deadline: .now() + slowAfter, execute: item)
                }
                if let timeout {
                    let item = DispatchWorkItem { [self] in
                        Log.error("\(label): no answer after \(timeout) s")
                        markTimedOut()
                        terminate(gracePeriod: 0.5)
                    }
                    timers.append(item)
                    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
                }
            }
            return (collected.events, exit)
        } onCancel: {
            terminate()
        }
    }
}
