import BoothCore
import Foundation

// Stand-ins for the engine and the system:
// - Simulated fakes (`FakeJobRunner`, `FakeSetupRunner`, `FakePreviewPlayer`, `FakeRemixer`) behave
//   like Main.dc.html and power `--demo`.
// - Manual and recording fakes do nothing on their own; tests and snapshot fixtures drive them.

@MainActor
extension EngineServices {
    /// `--demo`: simulated engine. `BOOTH_DEMO_FIRSTRUN=1` simulates first-run setup (~7 s);
    /// `BOOTH_DEMO_SETUP_FAIL=1` makes the first setup attempt fail halfway;
    /// `BOOTH_DEMO_ENGINE_WAIT=SECONDS` makes the engine that slow to answer ("Waiting for the
    /// engine" on the First run screen meanwhile).
    static func demo(environment: [String: String] = ProcessInfo.processInfo.environment) -> EngineServices {
        let firstRun = environment["BOOTH_DEMO_FIRSTRUN"] == "1"
        let locator = StubEngineLocator(availability: firstRun ? .needsSetup(nil) : .ready(.demo))
        if let wait = environment["BOOTH_DEMO_ENGINE_WAIT"].flatMap(Double.init), wait > 0 {
            locator.waitingOn = EngineCandidate(
                path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/booth/.venv/bin/booth").path,
                source: .launchArgument)
            locator.answerDelay = .seconds(wait)
        }
        return EngineServices(
            locator: locator,
            jobs: FakeJobRunner(),
            setup: FakeSetupRunner(failFirstAttempt: environment["BOOTH_DEMO_SETUP_FAIL"] == "1"),
            remixer: FakeRemixer(delay: .milliseconds(1200)),
            player: FakePreviewPlayer(),
            compareKey: OptionKeyMonitor())
    }

    /// Nothing runs and nothing ticks.
    static var inert: EngineServices {
        EngineServices(
            locator: StubEngineLocator(availability: .ready(.demo)),
            jobs: ManualJobRunner(),
            setup: ManualSetupRunner(),
            remixer: FakeRemixer(delay: .zero),
            player: RecordingPreviewPlayer())
    }
}

@MainActor
extension SystemServices {
    static var recording: SystemServices {
        SystemServices(notifier: RecordingNotifier(), loginItem: RecordingLoginItem(), workspace: RecordingWorkspace())
    }
}

@MainActor
extension AppDependencies {
    static var inert: AppDependencies {
        AppDependencies(engine: .inert, system: .recording)
    }
}

extension EngineInstallation {
    static let demo = EngineInstallation(
        executable: URL(fileURLWithPath: "/demo/booth"),
        info: EngineInfo(version: "0.1.0-demo", engines: EngineChoice.allCases.map(\.engineName), ready: true))
}

// MARK: - Simulated engine

final class StubEngineLocator: EngineLocating {
    var availability: EngineAvailability
    /// Reported through `onWaiting` before answering, like a slow `app-info`.
    var waitingOn: EngineCandidate?
    /// While set, `locate` waits until `answer()` is called.
    var holdsAnswer = false
    /// `locate` takes this long to answer.
    var answerDelay: Duration?
    private(set) var locateCount = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    init(availability: EngineAvailability) {
        self.availability = availability
    }

    func locate(onWaiting: @escaping @MainActor (EngineCandidate) -> Void) async -> EngineAvailability {
        locateCount += 1
        if let waitingOn { onWaiting(waitingOn) }
        if let answerDelay { try? await Task.sleep(for: answerDelay) }
        if holdsAnswer { await withCheckedContinuation { held.append($0) } }
        return availability
    }

    /// Lets every held `locate` return `availability`.
    func answer() {
        holdsAnswer = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

/// Simulates `enhance --events` the way the prototype does: start, progress through the
/// stage labels, done. File names steer it: "silent"/"no-audio" → `no_audio`, "corrupt" →
/// `decode_failed`, "music"/"mus_" → music detected.
final class FakeJobRunner: JobRunner {
    /// Multiplies every duration; tests use a small value.
    private let timeScale: Double
    private var running: [Job.ID: (task: Task<Void, Never>, events: @MainActor (EngineEvent) -> Void)] = [:]

    init(timeScale: Double = 1) {
        self.timeScale = timeScale
    }

    /// The real engine's `decode_failed` sentence (protocol.py `_unreadable`), so the demo's
    /// Error screen reads like the real one.
    static func unreadableMessage(name: String) -> String {
        "\(name) may be damaged or in a format Booth doesn't support. Nothing was changed."
    }

    /// Wall-clock seconds the demo spends on a file: 6–11, stable per name.
    static func demoSeconds(for name: String) -> Double {
        let hash = name.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        return 6 + Double(hash % 6)
    }

    func start(job: Job, options: RunOptions, events: @escaping @MainActor (EngineEvent) -> Void) {
        let scale = timeScale
        let task = Task { @MainActor [weak self] in
            await Self.simulate(job: job, options: options, timeScale: scale, events: events)
            self?.running[job.id] = nil
        }
        running[job.id] = (task, events)
    }

    func cancel(jobID: Job.ID) {
        guard let entry = running.removeValue(forKey: jobID) else { return }
        entry.task.cancel()
        // Like the real engine after SIGTERM.
        entry.events(.error(JobError(code: .cancelled, message: "Cancelled.")))
    }

    func cancelAll() {
        for id in Array(running.keys) { cancel(jobID: id) }
    }

    func pruneCache(in root: URL, protecting: Set<URL>) {} // the demo writes no stems

    private static func simulate(
        job: Job, options: RunOptions, timeScale: Double, events: @MainActor (EngineEvent) -> Void
    ) async {
        func pause(_ seconds: Double) async -> Bool {
            try? await Task.sleep(for: .seconds(max(0.001, seconds * timeScale)))
            return !Task.isCancelled
        }

        guard !Task.isCancelled else { return }
        let name = job.name.lowercased()
        events(.hello(EngineHello(version: "0.1.0-demo")))
        guard await pause(0.6) else { return }

        if name.contains("silent") || name.contains("no-audio") {
            events(.error(.noAudio(fileName: job.name)))
            return
        }
        if name.contains("corrupt") {
            events(.error(JobError(code: .decodeFailed, message: unreadableMessage(name: job.name))))
            return
        }

        let isVideo = job.mediaKind == .video
        let duration: Double = isVideo ? 192 : 48
        let realTotal = (duration * 0.57).rounded()
        events(.start(EngineStart(
            input: job.input.path, name: job.name, duration: duration, hasVideo: isVideo, hasAudio: true,
            meta: Formatting.meta(duration: duration, fileExtension: job.input.pathExtension, height: isVideo ? 1080 : nil),
            engine: options.engine.engineName, eta: realTotal)))

        let stages = EngineStage.plan(engine: options.engine, splitMusic: options.splitMusic)
        let seconds = demoSeconds(for: job.name)
        let tick = 0.1
        var progress = 0.0
        while progress < 1 {
            guard await pause(tick) else { return }
            progress = min(1, progress + tick / seconds)
            let stage = EngineStage.stage(at: progress, in: stages)
            events(.progress(EngineProgress(
                progress: progress, stage: stage?.id, label: stage?.label, eta: realTotal * (1 - progress))))
        }

        let output = options.output
        let wav = output.pathExtension.lowercased() == "wav" ? output : output.deletingPathExtension().appendingPathExtension("wav")
        events(.done(EngineDone(
            output: output.path,
            wav: wav.path,
            video: isVideo && options.keepVideo ? output.path : nil,
            stems: nil,
            took: realTotal,
            music: name.contains("music") || name.contains("mus_"),
            mix: options.mix)))
    }
}

/// Simulates `setup --events`: 1.13 GB over about seven seconds.
final class FakeSetupRunner: SetupRunning {
    static let totalBytes: Int64 = 1_130_000_000
    private let duration: Double
    private var failNextAttempt: Bool
    private var task: Task<Void, Never>?

    init(duration: Double = 7, failFirstAttempt: Bool = false) {
        self.duration = duration
        self.failNextAttempt = failFirstAttempt
    }

    func start(events: @escaping @MainActor (EngineEvent) -> Void) {
        task?.cancel()
        let duration = duration
        let failHalfway = failNextAttempt
        failNextAttempt = false
        task = Task { @MainActor in
            let tick = 0.25
            var fraction = 0.0
            while fraction < 1 {
                try? await Task.sleep(for: .seconds(tick * duration / 7))
                if Task.isCancelled { return }
                fraction = min(1, fraction + tick / 7)
                if failHalfway && fraction >= 0.45 {
                    events(.error(JobError(code: .setupFailed, message: "The download stopped before it finished. Check the connection and try again.")))
                    return
                }
                events(.setup(SetupProgress(
                    phase: "weights", label: "Downloading voice models",
                    bytesDone: Int64(Double(Self.totalBytes) * fraction), bytesTotal: Self.totalBytes,
                    eta: (1 - fraction) * 120)))
            }
            events(.done(EngineDone()))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Pretends to re-render after `delay`.
final class FakeRemixer: Remixing {
    private let delay: Duration
    private(set) var requests: [(result: JobResult, mix: Mix)] = []

    init(delay: Duration) {
        self.delay = delay
    }

    func remix(_ result: JobResult, to mix: Mix) async throws -> EngineDone {
        requests.append((result, mix))
        if delay > .zero { try await Task.sleep(for: delay) }
        return EngineDone(
            output: result.output.path, wav: result.wav?.path, video: result.video?.path,
            stems: result.stems?.path, took: 1.2, music: result.music, mix: mix)
    }
}

/// Plays nothing; moves the playhead across a 12-second clip like the prototype.
final class FakePreviewPlayer: PreviewPlaying {
    var onStatusChange: (@MainActor (PlaybackStatus) -> Void)?
    private var status = PlaybackStatus(isPlaying: false, playhead: 0)
    private var task: Task<Void, Never>?
    private var isLoaded = false
    private let clipSeconds: Double

    init(clipSeconds: Double = 12) {
        self.clipSeconds = clipSeconds
    }

    func load(_ result: JobResult?) {
        stopTicking()
        isLoaded = result != nil
        publish(PlaybackStatus(isPlaying: false, playhead: 0))
    }

    func play() {
        guard isLoaded, !status.isPlaying else { return }
        publish(PlaybackStatus(isPlaying: true, playhead: status.playhead >= 1 ? 0 : status.playhead))
        let tick = 1.0 / 30
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard let self, !Task.isCancelled else { return }
                let head = status.playhead + tick / clipSeconds
                if head >= 1 {
                    stopTicking()
                    publish(PlaybackStatus(isPlaying: false, playhead: 0))
                    return
                }
                publish(PlaybackStatus(isPlaying: true, playhead: head))
            }
        }
    }

    func pause() {
        stopTicking()
        if status.isPlaying { publish(PlaybackStatus(isPlaying: false, playhead: status.playhead)) }
    }

    func seek(to fraction: Double) {
        publish(PlaybackStatus(isPlaying: status.isPlaying, playhead: min(1, max(0, fraction))))
    }

    func setGains(_ gains: StemGains) {}
    func setComparing(_ comparing: Bool) {}

    private func stopTicking() {
        task?.cancel()
        task = nil
    }

    private func publish(_ new: PlaybackStatus) {
        status = new
        onStatusChange?(new)
    }
}

// MARK: - Manual and recording fakes

/// Records starts and cancels; the test sends events.
final class ManualJobRunner: JobRunner {
    struct Started {
        var job: Job
        var options: RunOptions
        var events: @MainActor (EngineEvent) -> Void
    }

    private(set) var started: [Started] = []
    private(set) var cancelled: [Job.ID] = []
    private(set) var cancelAllCount = 0
    /// Every prune request: the root and the protected directories.
    private(set) var prunes: [(root: URL, protecting: Set<URL>)] = []

    func start(job: Job, options: RunOptions, events: @escaping @MainActor (EngineEvent) -> Void) {
        started.append(Started(job: job, options: options, events: events))
    }

    func cancel(jobID: Job.ID) {
        cancelled.append(jobID)
    }

    func cancelAll() {
        cancelAllCount += 1
    }

    func pruneCache(in root: URL, protecting: Set<URL>) {
        prunes.append((root, protecting))
    }

    /// Delivers `event` to the job's callback, as the runner would.
    func send(_ event: EngineEvent, to jobID: Job.ID) {
        started.last { $0.job.id == jobID }?.events(event)
    }
}

final class ManualSetupRunner: SetupRunning {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var events: (@MainActor (EngineEvent) -> Void)?

    func start(events: @escaping @MainActor (EngineEvent) -> Void) {
        startCount += 1
        self.events = events
    }

    func cancel() {
        cancelCount += 1
    }

    func send(_ event: EngineEvent) {
        events?(event)
    }
}

final class RecordingPreviewPlayer: PreviewPlaying {
    var onStatusChange: (@MainActor (PlaybackStatus) -> Void)?
    private(set) var loaded: [JobResult?] = []
    private(set) var gains: [StemGains] = []
    private(set) var comparing: [Bool] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seeks: [Double] = []
    /// Every call in order: "load", "play", "pause", "seek", "setGains", "setComparing".
    private(set) var calls: [String] = []

    func load(_ result: JobResult?) { loaded.append(result); calls.append("load") }
    func play() { playCount += 1; calls.append("play") }
    func pause() { pauseCount += 1; calls.append("pause") }
    func seek(to fraction: Double) { seeks.append(fraction); calls.append("seek") }
    func setGains(_ gains: StemGains) { self.gains.append(gains); calls.append("setGains") }
    func setComparing(_ comparing: Bool) { self.comparing.append(comparing); calls.append("setComparing") }
}

/// Reports ⌥ only when the test says so.
final class ManualCompareKey: CompareKeyWatching {
    private(set) var isWatching = false
    private(set) var startCount = 0
    private var onChange: (@MainActor (Bool) -> Void)?
    private var isHeld = false

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        startCount += 1
        isWatching = true
        self.onChange = onChange
    }

    func stop() {
        if isHeld { set(held: false) }
        isWatching = false
        onChange = nil
    }

    /// Presses or releases ⌥; ignored while not watching, like the real monitor.
    func set(held: Bool) {
        guard isWatching, held != isHeld else { return }
        isHeld = held
        onChange?(held)
    }
}

final class RecordingNotifier: Notifying {
    var onAction: (@MainActor (NotificationAction, Job.ID) -> Void)?
    private(set) var posted: [Job] = []
    private(set) var authorizationRequests = 0

    func requestAuthorization() { authorizationRequests += 1 }
    func postJobFinished(_ job: Job) { posted.append(job) }
}

final class RecordingLoginItem: LoginItemControlling {
    private(set) var calls: [Bool] = []

    func setEnabled(_ enabled: Bool) { calls.append(enabled) }
}

final class RecordingWorkspace: WorkspaceActing {
    /// What the next open panel "returns".
    var nextChoice: [URL] = []
    private(set) var revealed: [[URL]] = []
    private(set) var opened: [URL] = []
    private(set) var terminateCount = 0

    func chooseMediaFiles(completion: @escaping @MainActor ([URL]) -> Void) { completion(nextChoice) }
    func reveal(_ urls: [URL]) { revealed.append(urls) }
    func open(_ url: URL) { opened.append(url) }
    func terminate() { terminateCount += 1 }
}

/// Answers update checks with `answer`, a release or an error, after `delay`.
final class FixedUpdates: UpdateChecking {
    var answer: Result<Release, Error>
    var delay: Duration
    private(set) var checks = 0

    init(_ answer: Result<Release, Error>, delay: Duration = .zero) {
        self.answer = answer
        self.delay = delay
    }

    func latestRelease() async throws -> Release {
        checks += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        return try answer.get()
    }
}

/// Reports the same video traits for every file (nil: no video anywhere).
struct FixedVideoInspector: VideoInspecting {
    var traits: VideoTraits?

    func inspect(_ url: URL) async -> VideoTraits? { traits }
}
