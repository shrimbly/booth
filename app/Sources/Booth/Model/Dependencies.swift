import BoothCore
import Foundation

// Everything AppModel needs from the outside world. The engine side (Engine/, Audio/) and the
// system side (Shell/) each provide one bundle; --demo swaps the engine bundle for fakes.
// All protocols are main-actor bound: implementations hop off the main thread internally and
// call back on the main actor.

// MARK: - Engine side

/// Runs enhance jobs (SPEC §2.3). AppModel starts at most one job at a time.
@MainActor
protocol JobRunner: AnyObject {
    /// Starts processing `job.input`. The runner creates `options.stemsDirectory` and uses it as
    /// the working directory. Events arrive on the main actor and end with exactly one `.done`
    /// or `.error`; a cancelled job ends with `.error` code `cancelled`. A process that exits
    /// non-zero without either is reported as `engine_failed` with the stderr tail.
    func start(job: Job, options: RunOptions, events: @escaping @MainActor (EngineEvent) -> Void)

    /// SIGTERM to the job's process group, SIGKILL after 3 s. Unknown IDs are ignored.
    func cancel(jobID: Job.ID)

    /// Quit: signal every running job before returning.
    func cancelAll()

    /// Deletes stems directories under `root` in the background (`JobCachePolicy`): never one
    /// in `protecting` (every job still listed), and of the rest only the newest few stay.
    func pruneCache(in root: URL, protecting: Set<URL>)
}

/// A validated engine executable.
struct EngineInstallation: Equatable {
    var executable: URL
    var info: EngineInfo
}

enum EngineAvailability: Equatable {
    /// `app-info` answered with protocol 1 and `ready: true`.
    case ready(EngineInstallation)
    /// No valid engine (every candidate absent or broken), or one whose models are missing:
    /// first-run setup has to run.
    case needsSetup(EngineInstallation?)
    /// This candidate's `app-info` never answered (often a macOS folder access prompt left
    /// open). The search stopped there: nothing may be installed over an engine that exists.
    case unresponsive(EngineCandidate)
}

/// Finds the engine in the SPEC §2.3 order and validates it with `app-info`.
@MainActor
protocol EngineLocating: AnyObject {
    /// `onWaiting` is called once for a candidate whose `app-info` is slow to answer, while the
    /// search keeps waiting for it.
    func locate(onWaiting: @escaping @MainActor (EngineCandidate) -> Void) async -> EngineAvailability
    /// The engine the last search (or setup's check after installing) stopped at because it
    /// didn't answer, if any.
    var unresponsiveCandidate: EngineCandidate? { get }
}

extension EngineLocating {
    func locate() async -> EngineAvailability {
        await locate(onWaiting: { _ in })
    }

    var unresponsiveCandidate: EngineCandidate? { nil }
}

/// First-run setup: creates the managed engine when none is valid, then runs `setup --events`.
@MainActor
protocol SetupRunning: AnyObject {
    /// Emits `.setup` progress (~4 Hz), then `.done` or `.error`, on the main actor.
    func start(events: @escaping @MainActor (EngineEvent) -> Void)
    func cancel()
}

/// Re-renders a finished job at a new mix (`booth remix`, SPEC §1.5).
@MainActor
protocol Remixing: AnyObject {
    /// Returns the engine's `done` event; throws a `JobError` on failure.
    func remix(_ result: JobResult, to mix: Mix) async throws -> EngineDone
}

struct PlaybackStatus: Equatable {
    var isPlaying: Bool
    /// 0…1
    var playhead: Double
}

/// Plays a finished job's preview stems with live mix gains (SPEC §2.4).
@MainActor
protocol PreviewPlaying: AnyObject {
    /// Set by AppModel. Report play/pause changes, the playhead (~30 Hz while playing), and
    /// reaching the end (paused, playhead 0).
    var onStatusChange: (@MainActor (PlaybackStatus) -> Void)? { get set }

    /// Prepares a finished job (nil unloads). Stops and rewinds. Keep it cheap — read audio
    /// lazily on first `play()` — and never fail without stems: play silence instead.
    func load(_ result: JobResult?)
    func play()
    func pause()
    /// 0…1
    func seek(to fraction: Double)
    func setGains(_ gains: StemGains)
    /// While true only the original stem is audible (~30 ms ramps).
    func setComparing(_ comparing: Bool)
}

/// Reports the ⌥ key for "Hold ⌥ to compare" (SPEC §2.4). AppModel starts it while the Done
/// screen is visible in the open popover and stops it otherwise. Must work without the
/// Accessibility permission.
@MainActor
protocol CompareKeyWatching: AnyObject {
    /// Calls `onChange` on the main actor whenever ⌥ goes down or up.
    func start(onChange: @escaping @MainActor (_ isHeld: Bool) -> Void)
    /// Stops watching. Reports a release first if ⌥ was down, so comparing never sticks.
    func stop()
}

struct EngineServices {
    var locator: EngineLocating
    var jobs: JobRunner
    var setup: SetupRunning
    var remixer: Remixing
    var player: PreviewPlaying
    var compareKey: CompareKeyWatching

    /// `compareKey` defaults to one that never reports ⌥ (tests, snapshots).
    @MainActor
    init(
        locator: EngineLocating, jobs: JobRunner, setup: SetupRunning, remixer: Remixing, player: PreviewPlaying,
        compareKey: CompareKeyWatching? = nil
    ) {
        self.locator = locator
        self.jobs = jobs
        self.setup = setup
        self.remixer = remixer
        self.player = player
        self.compareKey = compareKey ?? ManualCompareKey()
    }
}

// MARK: - System side

enum NotificationAction: Equatable {
    /// The notification body or its "Compare" action.
    case compare
    case showInFinder
}

/// User notifications (UNUserNotificationCenter).
@MainActor
protocol Notifying: AnyObject {
    /// Set by AppModel; call it when the user clicks a notification or one of its actions.
    var onAction: (@MainActor (NotificationAction, Job.ID) -> Void)? { get set }
    func requestAuthorization()
    /// "<name> is out of the booth." AppModel only calls this while the popover is closed.
    func postJobFinished(_ job: Job)
}

/// The "Open at login" switch (SMAppService.mainApp).
@MainActor
protocol LoginItemControlling: AnyObject {
    func setEnabled(_ enabled: Bool)
}

/// Bits of AppKit the model needs, behind a seam so it stays testable.
@MainActor
protocol WorkspaceActing: AnyObject {
    /// An open panel for audio and movie files, multiple selection. Cancel → `[]`.
    func chooseMediaFiles(completion: @escaping @MainActor ([URL]) -> Void)
    func reveal(_ urls: [URL])
    func terminate()
}

/// What a video file looks like, for the Done screen's picture.
struct VideoTraits: Equatable, Sendable {
    /// Display width ÷ height.
    var aspect: Double
    /// Where the audio track starts on the file's timeline, in seconds.
    var audioStart: Double
}

/// Reads a file's video track (AVFoundation in the app). nil when it has none or can't be read.
protocol VideoInspecting: Sendable {
    func inspect(_ url: URL) async -> VideoTraits?
}

/// Sees no video anywhere: the default for tests and snapshots.
struct NoVideoInspector: VideoInspecting {
    func inspect(_ url: URL) async -> VideoTraits? { nil }
}

struct SystemServices {
    var notifier: Notifying
    var loginItem: LoginItemControlling
    var workspace: WorkspaceActing
    var video: VideoInspecting = NoVideoInspector()
}

struct AppDependencies {
    var engine: EngineServices
    var system: SystemServices
}
