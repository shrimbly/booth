import BoothCore
import Foundation
import Observation

/// The single source of truth (SPEC §2.2), mirroring Main.dc.html's state machine.
///
/// - The UI reads state and derived values and calls intents.
/// - The shell drives `toggleOpen()` / `open(screen:)` / `close()` / `enqueue(_:)`, writes
///   `dropHover` and `iconTarget`, and renders `glyphMode` / `glyphProgress` / `pulse`.
/// - The engine side feeds it through the protocols in Dependencies.swift.
@MainActor
@Observable
final class AppModel {
    // MARK: Popover

    private(set) var isOpen = false
    /// The requested screen (`s.view`). Show `effectiveScreen`, which falls back when the data
    /// behind a request is gone.
    private(set) var screen: PopoverScreen = .idle
    /// Where Settings → Back returns to.
    private(set) var previousScreen: PopoverScreen = .idle

    // MARK: Jobs

    /// Queued, working and done jobs in arrival order. Failed and cancelled jobs are removed.
    private(set) var jobs: [Job] = []
    /// The one job being processed.
    private(set) var activeID: Job.ID?
    /// The job the Working/Done screen is about.
    private(set) var focusID: Job.ID?
    /// A job finished while the popover was closed.
    private(set) var unseen = false
    /// Finished jobs whose Done screen hasn't been in the open popover yet, oldest first: they
    /// finished while it was closed or showed something else. Done and the next open move on to
    /// them, and their stems are kept until then.
    private(set) var unseenIDs: [Job.ID] = []

    // MARK: Errors

    /// A failed job's error, shown on the Error screen until dismissed or another file arrives.
    private(set) var error: JobError?
    private(set) var errorFileName: String?
    /// How many files the error is about: more than one only for a rejected batch of unsupported files.
    private(set) var errorFileCount = 1

    // MARK: Setup

    private(set) var setup: SetupState = .checking

    // MARK: Drag and drop (written by the shell)

    /// A file is being dragged over the open popover.
    var dropHover = false
    /// A file is being dragged over the menu bar icon.
    var iconTarget = false
    /// True for 150 ms after files are accepted: the icon's click pulse.
    private(set) var pulse = false

    // MARK: Done screen

    /// Slider positions for the focused done job.
    private(set) var mix = Mix.standard
    /// The mix its output file was last rendered with.
    private(set) var savedMix = Mix.standard
    /// Jobs whose Save (remix) is running. Saves are per job: one job's remix never blocks or
    /// relabels another job's Save.
    private(set) var savingJobs: Set<Job.ID> = []
    /// Each job's last Save that failed, cleared when it is tried again or the job is focused anew.
    private(set) var saveErrors: [Job.ID: JobError] = [:]
    private(set) var isPlaying = false
    /// 0…1
    private(set) var playhead = 0.0
    /// The original is playing instead of the enhanced mix (⌥ held).
    private(set) var isComparing = false
    /// The mix sliders are showing. Each newly focused job starts with them hidden.
    private(set) var isMixOpen = false
    /// The focused job's picture, once its file has been read; nil for audio-only jobs.
    private(set) var previewVideo: PreviewVideo?

    let settings: Settings

    @ObservationIgnored let dependencies: AppDependencies
    @ObservationIgnored private let stemsRoot: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pulseTask: Task<Void, Never>?
    /// A job that finished while Working showed it. Working keeps it on screen, full, for
    /// `finishHold`, so the bar visibly completes before Done takes over.
    private(set) var finishingID: Job.ID?
    @ObservationIgnored private let finishHold: Duration
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var didShutDown = false
    @ObservationIgnored private var isWatchingCompareKey = false
    /// A search for the engine is running (`checkEngine`).
    @ObservationIgnored private var isLocating = false
    @ObservationIgnored private var locateTask: Task<Void, Never>?
    @ObservationIgnored private var videoTask: Task<Void, Never>?
    /// The engine whose silence failed the last search: Try again asks it again rather than
    /// running setup (which would install a second engine).
    @ObservationIgnored private var unresponsiveEngine: EngineCandidate?

    /// Errors this soon after a drop are the prototype's instant rejection (no audio, unreadable):
    /// they open the popover. Later failures only flag the icon.
    nonisolated static let instantErrorWindow: TimeInterval = 3

    /// How long Working holds a job that has just finished: its fill glides to full
    /// (`PopoverMotion.progressSeconds`), then rests for 200 ms before Done.
    static let finishHold = Duration.seconds(PopoverMotion.progressSeconds + 0.2)

    /// How many finished jobs wait to be seen at most. Older ones drop out of reach, so a long
    /// session nobody looks at doesn't keep every job's stems.
    static let unseenLimit = 10

    nonisolated static let defaultStemsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Booth/jobs", isDirectory: true)

    init(
        settings: Settings,
        dependencies: AppDependencies,
        stemsRoot: URL = AppModel.defaultStemsRoot,
        now: @escaping () -> Date = Date.init,
        finishHold: Duration = .zero
    ) {
        self.settings = settings
        self.dependencies = dependencies
        self.stemsRoot = stemsRoot
        self.now = now
        self.finishHold = finishHold
        dependencies.engine.player.onStatusChange = { [weak self] status in
            self?.playbackDidChange(status)
        }
        dependencies.system.notifier.onAction = { [weak self] action, jobID in
            self?.handleNotification(action, jobID: jobID)
        }
        trackCompareKey()
    }

    // MARK: - Derived state

    var activeJob: Job? { job(activeID) }
    var focusJob: Job? { job(focusID) }
    /// The job Working shows: the one that has just finished while it is still in focus, else
    /// the active one.
    var workingJob: Job? { isFocusFinishing ? job(finishingID) : activeJob }
    private var isFocusFinishing: Bool { finishingID != nil && finishingID == focusID }
    var queuedJobs: [Job] { jobs.filter { $0.state == .queued } }

    /// The prototype's inputs for the pure view logic in BoothCore.
    var context: PopoverContext {
        PopoverContext(
            isOpen: isOpen,
            requested: screen,
            setupIncomplete: setup.showsSetupScreen,
            setupFailed: setup.isFailed,
            hasError: error != nil,
            hasActiveJob: activeID != nil,
            hasFocus: focusID != nil,
            focusIsDone: focusJob?.state == .done,
            unseen: unseen,
            iconTarget: iconTarget,
            focusIsFinishing: isFocusFinishing)
    }

    /// The screen to draw.
    var effectiveScreen: PopoverScreen { PopoverLogic.effectiveScreen(context) }

    var glyphMode: GlyphMode { PopoverLogic.glyphMode(context) }

    /// Drives the working glyph: the active job's progress, else setup's.
    var glyphProgress: Double {
        if let activeJob { return activeJob.progress }
        return setup.showsSetupScreen ? setup.fraction : 1
    }

    /// Every screen but Settings takes drops.
    var acceptsDrops: Bool { effectiveScreen.acceptsDrops }

    /// The job the current screen is about: the active job on Working, the focused one on Done.
    var displayedJob: Job? {
        switch effectiveScreen {
        case .working: workingJob
        case .done: focusJob
        default: nil
        }
    }

    /// Done screen: the job still in the booth ("In the booth: name · 34%"), if any.
    var backgroundJob: Job? { effectiveScreen == .done ? activeJob : nil }

    /// Working screen: `"52% · Restoring the voice · about 1 min left"`.
    var statusLine: String? {
        workingJob.map { Formatting.statusLine(progress: $0.progress, stageLabel: $0.stageLabel, eta: $0.eta) }
    }

    /// Working screen: `"Next: a.wav and 2 more"`; nil when nothing is queued.
    var queueLine: String? { Formatting.queueLine(queuedJobs.map(\.name)) }

    var backgroundJobLabel: String? {
        backgroundJob.map { Formatting.backgroundJobLabel(name: $0.name, progress: $0.progress) }
    }

    /// Music was detected in the focused job; otherwise the Music slider is left out.
    var musicDetected: Bool { focusJob?.result?.music ?? false }

    var isMixDirty: Bool { mix != savedMix }

    /// The focused job's Save is running ("Saving…").
    var isSaving: Bool { focusID.map(savingJobs.contains) ?? false }

    /// The focused job's last failed Save ("Try again").
    var saveError: JobError? { focusID.flatMap { saveErrors[$0] } }

    /// The Done screen offers its "Video" toggle.
    var canShowVideo: Bool { previewVideo != nil }

    /// The picture the Done screen draws: the focused job's video, when the user has it on.
    var shownVideo: PreviewVideo? { settings.showVideo ? previewVideo : nil }

    /// Holding ⌥ compares only while a finished job's Done screen is in the open popover.
    var wantsCompareKey: Bool { isOpen && effectiveScreen == .done && focusJob?.result != nil }

    /// Normalised bar levels for the Done waveform (56 values; draw with
    /// `WaveformBars.height(forLevel:)`). Empty when no done job is focused. Real manifests use
    /// the perceptual (dB) mapping; the synthetic demo bars stay linear.
    var waveformLevels: [Double] {
        guard let result = focusJob?.result else { return [] }
        return WaveformBars.levels(
            bars: result.waveformSource, mix: mix, curve: result.curve,
            includeMusic: result.music, comparing: isComparing, perceptual: result.manifest != nil)
    }

    var errorTitle: String? { error.map { Formatting.errorTitle(for: $0.code, fileCount: errorFileCount) } }
    var errorBody: String? { error.map(Formatting.errorBody(for:)) }

    /// First run, left: `"412 MB of 1.13 GB"`.
    var setupBytesText: String? {
        guard case .running(let info) = setup else { return nil }
        return Formatting.setupBytes(done: info.bytesDone, total: info.bytesTotal)
    }

    /// First run, right: `"about 2 min left"` / `"Done"`.
    var setupTimeLeftText: String? {
        guard case .running(let info) = setup else { return nil }
        return Formatting.setupTimeLeft(fraction: info.fraction, eta: info.eta)
    }

    var setupFailureMessage: String? {
        guard case .failed(let message) = setup else { return nil }
        return message
    }

    /// First run while the engine is slow to answer (title `Formatting.engineWaitingTitle`);
    /// nil otherwise.
    var setupWaitingText: String? {
        guard case .waitingForEngine(let folder) = setup else { return nil }
        return Formatting.engineWaitingBody(folder: folder)
    }

    var version: String { AppInfo.version }

    func job(_ id: Job.ID?) -> Job? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Call once after launch: locates the engine (running setup if needed) and applies
    /// preferences that have side effects.
    func launch() {
        dependencies.system.notifier.requestAuthorization()
        dependencies.system.loginItem.setEnabled(settings.openAtLogin)
        locateTask = Task { await checkEngine() }
    }

    /// Locates the engine; ready → jobs may start; missing or incomplete → first-run setup
    /// begins. An engine slow to answer shows "Waiting for the engine"; one that never answers
    /// fails setup with a message, and nothing is installed over it.
    func checkEngine() async {
        guard !setup.isRunning, !isLocating, !didShutDown else { return }
        isLocating = true
        defer { isLocating = false }
        if !setup.isWaitingForEngine { setup = .checking }
        unresponsiveEngine = nil
        let availability = await dependencies.engine.locator.locate { [weak self] candidate in
            self?.engineIsSlow(candidate)
        }
        guard !didShutDown else { return }
        switch availability {
        case .ready(let installation):
            Log.info("engine ready: \(installation.executable.path) (version \(installation.info.version))")
            setupDidFinish()
        case .needsSetup(let installation):
            Log.info("engine needs setup: \(installation?.executable.path ?? "no engine found")")
            beginSetup()
        case .unresponsive(let candidate):
            Log.error("engine not answering: \(candidate.path); setup is not started")
            unresponsiveEngine = candidate
            setup = .failed(message: Formatting.engineUnresponsiveMessage(folder: Self.engineFolder(candidate)))
        }
    }

    /// The folder to name for an engine, as the user would write it (`~/projects/sv`).
    nonisolated static func engineFolder(_ candidate: EngineCandidate) -> String {
        Formatting.engineFolder(executablePath: candidate.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private func engineIsSlow(_ candidate: EngineCandidate) {
        guard isLocating else { return }
        Log.info("waiting for the engine at \(candidate.path)")
        setup = .waitingForEngine(folder: Self.engineFolder(candidate))
    }

    /// Cancels everything in flight. Idempotent; called on quit.
    func shutdown() {
        guard !didShutDown else { return }
        didShutDown = true
        Log.info("shutting down with \(jobs.filter { !$0.state.isFinished }.count) unfinished job(s)")
        locateTask?.cancel() // a waiting app-info must not outlive the app
        finishTask?.cancel()
        dependencies.engine.jobs.cancelAll()
        if setup.isRunning { dependencies.engine.setup.cancel() }
        dependencies.engine.player.pause()
    }

    // MARK: - Popover intents

    func toggleOpen() {
        if isOpen { close() } else { open() }
    }

    /// Opens on `screen`, or on the prototype's `viewOnOpen` when nil.
    func open(screen requested: PopoverScreen? = nil) {
        if let requested {
            screen = requested
        } else {
            screen = PopoverLogic.viewOnOpen(context)
            if let activeID {
                setFocus(activeID)
            } else if screen == .idle || (screen == .done && unseen), let next = unseenIDs.first {
                // A finished file not yet seen comes before the drop zone, and what the lamp
                // announced before the Done screen last left open.
                setFocus(next)
                screen = .done
            }
        }
        unseen = false
        if !isOpen {
            isOpen = true
            Log.info("popover opened on \(effectiveScreen.rawValue)")
        }
        noteDoneScreenSeen()
    }

    func close() {
        guard isOpen else { return }
        // Closed first: a job Working was holding goes to Done but still waits to be seen.
        isOpen = false
        endFinishHold()
        dropHover = false
        stopPlayback()
        Log.info("popover closed")
    }

    func showSettings() {
        endFinishHold()
        if screen != .settings { previousScreen = effectiveScreen }
        screen = .settings
        stopPlayback()
    }

    /// Settings → Back; on any other screen behaves like dismissing.
    func back() {
        if screen == .settings {
            if previousScreen == .working, let focusID, focusJob?.state == .done {
                // The file Working showed finished behind Settings: land on its Done screen.
                showDone(focusID)
            } else {
                screen = previousScreen
                if screen == .working, let activeID { setFocus(activeID) }
                noteDoneScreenSeen()
            }
        } else {
            dismissError()
        }
    }

    /// Error × → back to whatever is going on: the job in the booth, else the finished job the
    /// error interrupted, else a finished one not yet seen, else Idle.
    func dismissError() {
        error = nil
        errorFileName = nil
        if let activeID {
            // Working is about the job in the booth: its finish must find it in focus.
            setFocus(activeID)
            screen = .working
        } else if let focusID, focusJob?.state == .done {
            showDone(focusID)
        } else if let next = unseenIDs.first {
            showDone(next)
        } else {
            screen = .idle
        }
    }

    /// Error screen's "Choose another". Dismissing may pass a finished job's Done screen on the
    /// way to the chooser; that doesn't count as seeing it, since the chosen file replaces it.
    func chooseAnother() {
        let waiting = unseenIDs
        dismissError()
        unseenIDs = waiting
        chooseFiles()
    }

    /// First run's "Run in background": setup carries on with the popover closed.
    func runSetupInBackground() {
        close()
    }

    /// First run's "Try again" after a failure.
    func retrySetup() {
        guard setup.isFailed else { return }
        // The engine exists but didn't answer, at launch or in setup's own check after installing:
        // ask it again, showing that Booth is waiting for it, and never install another.
        if let engine = unresponsiveEngine ?? dependencies.engine.locator.unresponsiveCandidate {
            setup = .waitingForEngine(folder: Self.engineFolder(engine))
            locateTask = Task { await checkEngine() }
        } else {
            beginSetup()
        }
    }

    /// Done screen's "Done": on to the next finished file not yet seen, else to the file still in
    /// the booth, else back to the drop zone. The output and the job stay as they are.
    func closeDone() {
        guard effectiveScreen == .done else { return }
        unseen = false
        noteDoneScreenSeen()
        if let next = unseenIDs.first {
            showDone(next)
        } else {
            setFocus(activeID)
            screen = activeID != nil ? .working : .idle
        }
    }

    /// Done screen's "In the booth: …" button.
    func switchToActive() {
        guard let activeID else { return }
        screen = .working
        setFocus(activeID)
    }

    /// A notification's "Compare": open on that job's Done screen, ready to play. A job whose
    /// stems were cleared since (it fell off the waiting list) has nothing to play: show its file.
    func openJob(_ id: Job.ID) {
        guard let job = job(id), job.state == .done else { return }
        if let stems = job.result?.stems, !OutputNaming.fileExists(stems) {
            revealOutput(of: id)
            return
        }
        setFocus(id)
        open(screen: .done)
    }

    // MARK: - Job intents

    /// Queues files and starts the first if the booth is free. Returns the accepted URLs.
    /// No-audio and decoding failures come back from the runner.
    ///
    /// Types Booth doesn't take (`OutputNaming`) are left out. When nothing at all is accepted
    /// and `reportingRejections` is true, the Error screen opens saying so, like the engine's
    /// instant rejections; when some files were accepted, the rest are only logged. Callers
    /// with their own way of saying it (the ⌃⌥E capsule) pass false.
    @discardableResult
    func enqueue(_ urls: [URL], reportingRejections: Bool = true) -> [URL] {
        let (supported, rejected) = OutputNaming.partition(urls)
        if !rejected.isEmpty {
            Log.info("ignored unsupported: \(rejected.map(\.lastPathComponent).joined(separator: ", "))")
        }
        guard !supported.isEmpty else {
            if reportingRejections && !rejected.isEmpty { reportUnsupported(rejected) }
            return []
        }
        triggerPulse()
        for url in supported { add(url) }
        return supported
    }

    func chooseFiles() {
        dependencies.system.workspace.chooseMediaFiles { [weak self] urls in
            self?.enqueue(urls)
        }
    }

    func cancelActive() {
        // Working is showing a job that has already finished; the × must not cancel the next
        // file, which isn't on screen yet.
        guard !isFocusFinishing, let id = activeID else { return }
        Log.info("cancel \(job(id)?.name ?? id.uuidString)")
        // Forget the job before telling the runner: a runner that reports `cancelled` at once
        // (the demo's) then finds nothing to act on, instead of starting the next file itself
        // and having it overwritten below.
        jobs.removeAll { $0.id == id }
        activeID = nil
        dependencies.engine.jobs.cancel(jobID: id)
        startNextQueuedJob()
        setFocus(activeID)
        screen = activeID != nil ? .working : .idle
    }

    // MARK: - Done screen intents

    func togglePlay() {
        guard focusJob?.result != nil else { return }
        if isPlaying {
            isPlaying = false
            dependencies.engine.player.pause()
        } else {
            isPlaying = true
            dependencies.engine.player.play()
        }
    }

    func seek(to fraction: Double) {
        guard focusJob?.result != nil else { return }
        playhead = min(1, max(0, fraction))
        dependencies.engine.player.seek(to: playhead)
    }

    func setComparing(_ comparing: Bool) {
        guard comparing != isComparing else { return }
        isComparing = comparing
        dependencies.engine.player.setComparing(comparing)
    }

    func setMix(_ newMix: Mix) {
        mix = newMix.clamped
        applyGains()
    }

    func revertMix() {
        setMix(savedMix)
    }

    /// The "Mix" toggle: shows or hides the sliders.
    func toggleMix() {
        isMixOpen.toggle()
    }

    /// The "Video" toggle. Remembered: once on, every video job shows its picture.
    func toggleVideo() {
        guard canShowVideo else { return }
        settings.showVideo.toggle()
    }

    /// Re-renders the focused job's output at the current mix.
    func saveMix() {
        guard let id = focusID, !savingJobs.contains(id), isMixDirty, let result = focusJob?.result else { return }
        let target = mix
        savingJobs.insert(id)
        saveErrors[id] = nil
        Log.info("remix \(job(id)?.name ?? "") to s\(target.speech) b\(target.background) m\(target.music)")
        Task { [weak self] in
            guard let self else { return }
            do {
                let done = try await dependencies.engine.remixer.remix(result, to: target)
                mixDidSave(done, mix: target, jobID: id)
            } catch {
                mixDidFail(error, jobID: id)
            }
        }
    }

    func revealInFinder() {
        guard let focusID else { return }
        revealOutput(of: focusID)
    }

    /// Reveals a job's output, or its input while there is no output on disk yet.
    func revealOutput(of id: Job.ID) {
        guard let job = job(id) else { return }
        let target = job.result?.output ?? job.output
        if let target, OutputNaming.fileExists(target) {
            dependencies.system.workspace.reveal([target])
        } else {
            dependencies.system.workspace.reveal([job.input])
        }
    }

    // MARK: - Settings intents

    func setEngine(_ engine: EngineChoice) {
        settings.engine = engine
    }

    func setKeepVideo(_ keep: Bool) {
        settings.keepVideo = keep
    }

    func setNoSplit(_ noSplit: Bool) {
        settings.noSplit = noSplit
    }

    func setOpenAtLogin(_ enabled: Bool) {
        settings.openAtLogin = enabled
        dependencies.system.loginItem.setEnabled(enabled)
    }

    func quit() {
        shutdown()
        dependencies.system.workspace.terminate()
    }

    // MARK: - Shell helpers

    /// The icon's click pulse (scale 1.25 for 150 ms).
    func triggerPulse() {
        pulse = true
        pulseTask?.cancel()
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.pulse = false
        }
    }

    // MARK: - Queue

    /// Nothing handed over is a type Booth takes: open on the Error screen, as the engine's
    /// instant rejections do.
    private func reportUnsupported(_ rejected: [URL]) {
        let names = rejected.map(\.lastPathComponent)
        Log.info("nothing to enhance: \(names.joined(separator: ", "))")
        stopPlayback()
        error = JobError(code: .decodeFailed, message: Formatting.unsupportedFileBody(names: names))
        errorFileName = names.first
        errorFileCount = names.count
        open(screen: .error)
    }

    private func add(_ url: URL) {
        let busy = activeID != nil || !setup.isReady
        let job = Job(input: url, enqueuedAt: now())
        jobs.append(job)
        error = nil
        errorFileName = nil
        Log.info("enqueued \(url.path)\(busy ? " (queued)" : "")")
        if !busy {
            begin(job.id)
            setFocus(job.id)
        }
        if isOpen && !busy { screen = .working }
        if isOpen && busy && (screen == .idle || screen == .error) {
            screen = setup.showsSetupScreen ? .firstrun : .working
            if screen == .working, let activeID { setFocus(activeID) }
        }
    }

    private func startNextQueuedJob() {
        guard activeID == nil, setup.isReady, let next = queuedJobs.first else { return }
        begin(next.id)
    }

    private func begin(_ id: Job.ID) {
        // Cancelling during shutdown must not start the next file.
        guard !didShutDown, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let reserved = Set(jobs.compactMap { $0.result?.output ?? $0.output }.map(\.standardizedFileURL.path))
        let output = OutputNaming.outputURL(for: jobs[index].input, keepVideo: settings.keepVideo) { url in
            OutputNaming.fileExists(url) || reserved.contains(url.standardizedFileURL.path)
        }
        jobs[index].state = .working
        jobs[index].output = output
        jobs[index].startedAt = now()
        activeID = id
        let options = settings.runOptions(output: output, stemsDirectory: stemsDirectory(for: id))
        Log.info("start \(jobs[index].name) → \(output.lastPathComponent) [\(options.engine.engineName)]")
        dependencies.engine.jobs.start(job: jobs[index], options: options) { [weak self] event in
            self?.handle(event, forJob: id)
        }
        pruneJobCache()
    }

    private func stemsDirectory(for id: Job.ID) -> URL {
        stemsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Jobs that can still use their stems keep them: queued and working ones, the focused one,
    /// finished ones waiting to be seen, and any whose Save is running. No screen leads back to
    /// the other finished jobs, so theirs are left to `JobCachePolicy`'s newest few.
    private func pruneJobCache() {
        let inReach = jobs.filter { job in
            job.state != .done || job.id == focusID || unseenIDs.contains(job.id) || savingJobs.contains(job.id)
        }
        var inUse = Set(inReach.map { stemsDirectory(for: $0.id) })
        inUse.formUnion(inReach.compactMap { $0.result?.stems })
        dependencies.engine.jobs.pruneCache(in: stemsRoot, protecting: inUse)
    }

    private func handle(_ event: EngineEvent, forJob id: Job.ID) {
        // Events for a job that was cancelled and removed are dropped here.
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].state.isFinished else { return }
        jobs[index].apply(event)
        switch jobs[index].state {
        case .done: jobDidFinish(id)
        case .failed, .cancelled: jobDidFail(id)
        case .queued, .working: break
        }
    }

    private func jobDidFinish(_ id: Job.ID) {
        loadManifest(for: id)
        guard let job = job(id) else { return }
        Log.info("done \(job.name) → \(job.result?.output.path ?? "?") in \(Formatting.clock(job.result?.took ?? 0))")
        // Judged by what is on screen, before the job leaves the booth.
        let watching = isOpen && effectiveScreen == .working && workingJob?.id == id
        activeID = nil
        // Every finished job waits to be seen until its Done screen shows, however it got there.
        unseenIDs.append(id)
        if unseenIDs.count > Self.unseenLimit {
            let dropped = unseenIDs.removeFirst()
            Log.info("\(self.job(dropped)?.name ?? dropped.uuidString) is no longer waiting to be seen")
        }
        startNextQueuedJob()
        if watching {
            // The player was loaded while the job had no result (setFocus during Working).
            setFocus(id, refresh: true)
            holdFinishedJob(id)
        } else {
            // Reload the player whenever this job is still the focus, even with Settings in
            // front: Back lands on its Done screen and Play must have the stems.
            if focusID == id { setFocus(id, refresh: true) }
            if !isOpen {
                unseen = true
                dependencies.system.notifier.postJobFinished(job)
            }
        }
    }

    /// Working shows the finished job for `finishHold` (its fill completes, then rests a beat),
    /// then Done takes over.
    private func holdFinishedJob(_ id: Job.ID) {
        guard finishHold > .zero else {
            showDone(id)
            return
        }
        finishingID = id
        finishTask?.cancel()
        finishTask = Task { [weak self, finishHold] in
            try? await Task.sleep(for: finishHold)
            guard !Task.isCancelled, let self else { return }
            endFinishHold()
            noteDoneScreenSeen()
        }
    }

    /// Done takes over now if Working was holding a finished job and is still showing it.
    /// Closing the popover or opening Settings ends the hold early, so they see the job as done;
    /// it waits to be seen until its Done screen is actually shown.
    private func endFinishHold() {
        guard let id = finishingID else { return }
        finishTask?.cancel()
        finishTask = nil
        finishingID = nil
        if screen == .working && focusID == id { screen = .done }
    }

    private func jobDidFail(_ id: Job.ID) {
        guard let failed = job(id), let failure = failed.error else { return }
        if failure.code == .cancelled {
            Log.info("job \(failed.name) cancelled")
        } else {
            Log.error("job \(failed.name) failed: \(failure.code) \(failure.message)")
        }
        jobs.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        if focusID == id { setFocus(nil) }

        switch failure.code {
        case .cancelled:
            break
        case .setupRequired:
            // The engine lost its models: put the file back at the front and set up again.
            let retry = Job(input: failed.input, enqueuedAt: failed.enqueuedAt)
            jobs.insert(retry, at: jobs.firstIndex { $0.state == .queued } ?? jobs.endIndex)
            beginSetup()
        default:
            error = failure
            errorFileName = failed.name
            errorFileCount = 1
            // The Error screen replaces whatever was showing, including a Done screen that was
            // playing another job: nothing may keep sounding behind it.
            stopPlayback()
            if isOpen {
                screen = .error
            } else if now().timeIntervalSince(failed.enqueuedAt) < Self.instantErrorWindow {
                open(screen: .error)
            }
        }
        startNextQueuedJob()
    }

    private func loadManifest(for id: Job.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let stems = jobs[index].result?.stems else { return }
        do {
            jobs[index].result?.manifest = try StemsManifest.load(from: stems)
        } catch {
            Log.error("could not read \(stems.path)/\(StemsManifest.fileName): \(error)")
        }
    }

    // MARK: - Setup

    private func beginSetup() {
        guard !didShutDown else { return }
        Log.info("setup started")
        setup = .running(SetupProgressInfo())
        dependencies.engine.setup.start { [weak self] event in
            self?.handleSetup(event)
        }
    }

    private func handleSetup(_ event: EngineEvent) {
        guard setup.isRunning else { return }
        var next = setup
        next.apply(event)
        switch next {
        case .ready:
            Log.info("setup finished")
            setupDidFinish()
        case .failed(let message):
            Log.error("setup failed: \(message)")
            setup = next
        case .running, .checking, .waitingForEngine:
            setup = next
        }
    }

    private func setupDidFinish() {
        setup = .ready
        if screen == .firstrun { screen = .idle }
        guard activeID == nil else { return }
        startNextQueuedJob()
        if let activeID {
            setFocus(activeID)
            if isOpen { screen = .working }
        }
    }

    // MARK: - Focus and playback

    /// Changing the focused job stops playback and loads the new job's mix and stems.
    private func setFocus(_ id: Job.ID?, refresh: Bool = false) {
        guard id != focusID || refresh else { return }
        focusID = id
        preparePlayback()
    }

    /// Shows a finished job's Done screen.
    private func showDone(_ id: Job.ID) {
        setFocus(id)
        screen = .done
        noteDoneScreenSeen()
    }

    /// A finished job stops waiting to be seen once its Done screen is in the open popover, but
    /// not while a drag only passes it: the drop replaces it with the new file.
    private func noteDoneScreenSeen() {
        guard isOpen, !iconTarget, !dropHover, effectiveScreen == .done, let focusID else { return }
        unseenIDs.removeAll { $0 == focusID }
    }

    private func preparePlayback() {
        let player = dependencies.engine.player
        player.pause()
        isPlaying = false
        // Always tell the player, not only when the model thinks it is comparing: a focus change
        // with ⌥ held must not leave the next job playing the original.
        player.setComparing(false)
        isComparing = false
        playhead = 0
        // The sliders go back to the saved mix, so this job's old Save failure no longer applies.
        // Other jobs' saves and failures are theirs.
        if let focusID { saveErrors[focusID] = nil }
        let result = focusJob?.result
        mix = result?.mix ?? .standard
        savedMix = mix
        // A save still running is shown, not tucked away with the sliders.
        isMixOpen = focusID.map(savingJobs.contains) ?? false
        player.load(result)
        if result != nil { applyGains() }
        loadVideo(for: result)
    }

    /// Reads the focused job's video, when it has one, for the Done screen's picture.
    private func loadVideo(for result: JobResult?) {
        videoTask?.cancel()
        previewVideo = nil
        guard let result, let duration = result.manifest?.duration,
              let url = PreviewVideo.source(for: result, fileExists: OutputNaming.fileExists) else { return }
        let id = focusID
        let inspector = dependencies.system.video
        videoTask = Task { [weak self] in
            let traits = await inspector.inspect(url)
            guard let self, !Task.isCancelled, focusID == id else { return }
            guard let traits else {
                Log.info("video: no picture in \(url.lastPathComponent)")
                return
            }
            previewVideo = PreviewVideo(url: url, aspect: traits.aspect, audioStart: traits.audioStart, duration: duration)
        }
    }

    private func stopPlayback() {
        if isPlaying {
            isPlaying = false
            dependencies.engine.player.pause()
        }
        setComparing(false)
    }

    private func applyGains() {
        guard let result = focusJob?.result else { return }
        dependencies.engine.player.setGains(mix.gains(curve: result.curve, includeMusic: result.music))
    }

    /// Starts or stops the ⌥ monitor as `wantsCompareKey` changes, re-arming itself after
    /// every change (observation fires once, before the new value is set).
    private func trackCompareKey() {
        let wanted = withObservationTracking {
            wantsCompareKey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackCompareKey() }
        }
        guard wanted != isWatchingCompareKey else { return }
        isWatchingCompareKey = wanted
        if wanted {
            dependencies.engine.compareKey.start { [weak self] isHeld in
                self?.setComparing(isHeld)
            }
        } else {
            dependencies.engine.compareKey.stop()
        }
    }

    private func playbackDidChange(_ status: PlaybackStatus) {
        if isPlaying != status.isPlaying { isPlaying = status.isPlaying }
        if playhead != status.playhead { playhead = status.playhead }
    }

    private func mixDidSave(_ done: EngineDone, mix saved: Mix, jobID id: Job.ID) {
        savingJobs.remove(id)
        saveErrors[id] = nil
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].result?.mix = saved
        if let output = done.output, !output.isEmpty {
            jobs[index].result?.output = URL(fileURLWithPath: output)
        }
        if focusID == id {
            // Refocusing during the save put the sliders back on the old mix; untouched since,
            // they follow the file to the mix it now has.
            let untouched = mix == savedMix
            savedMix = saved
            if untouched {
                mix = saved
                applyGains()
            }
        }
        Log.info("remix saved for \(jobs[index].name)")
    }

    private func mixDidFail(_ failure: Error, jobID id: Job.ID) {
        savingJobs.remove(id)
        let error = failure as? JobError ?? JobError(code: .internal, message: failure.localizedDescription)
        let name = job(id)?.name ?? id.uuidString
        Log.error("remix failed for \(name): \(error.code) \(error.message)")
        saveErrors[id] = error
        guard focusID != id else { return } // its Done screen says "Try again"
        // The job is off screen, so its Save button can't tell. Report it without interrupting:
        // the attention glyph while closed, the Error screen on the next open, and right away
        // only over Idle or Working, never over a Done or Settings screen in use.
        self.error = JobError(code: .engineFailed, message: Formatting.remixFailedBody(name: name))
        errorFileName = name
        errorFileCount = 1
        if isOpen && (effectiveScreen == .idle || effectiveScreen == .working) {
            screen = .error
        }
    }

    private func handleNotification(_ action: NotificationAction, jobID: Job.ID) {
        switch action {
        case .compare: openJob(jobID)
        case .showInFinder: revealOutput(of: jobID)
        }
    }
}

// MARK: - Fixtures

extension AppModel {
    /// Fixed states for `--render-states` (SPEC §3.9) and tests. The raw value is the snapshot
    /// file name prefix.
    enum Fixture: String, CaseIterable {
        case idle
        case idleDropHover = "idle-drophover"
        case firstrun
        case firstrunWaiting = "firstrun-waiting"
        case firstrunFailed = "firstrun-failed"
        case working
        case done
        case doneMix = "done-mix"
        case doneDirtyComparing = "done-dirty-comparing"
        case doneNoMusic = "done-nomusic"
        case doneVideo = "done-video"
        case doneVideoPortrait = "done-video-portrait"
        case doneVideoMix = "done-video-mix"
        case doneDropHover = "done-drophover"
        case settings
        case error

        /// The screen the fixture must show.
        var expectedScreen: PopoverScreen {
            switch self {
            case .idle, .idleDropHover: .idle
            case .firstrun, .firstrunWaiting, .firstrunFailed: .firstrun
            case .working: .working
            case .done, .doneMix, .doneDirtyComparing, .doneNoMusic, .doneVideo, .doneVideoPortrait, .doneVideoMix,
                 .doneDropHover: .done
            case .settings: .settings
            case .error: .error
            }
        }
    }

    /// A model frozen in `fixture`, open, with inert fakes (nothing runs or ticks). `progress` is
    /// how far the Working fixture's file has got, `file` names the file the Working and Done
    /// fixtures show, and `videoAspect` shapes the Done fixtures' picture; `--render-demo` sets them.
    static func fixture(
        _ fixture: Fixture, progress: Double = 0.48, file: String = "interview-take3.mp4", videoAspect: Double = 16 / 9
    ) -> AppModel {
        let model = AppModel(settings: Settings(store: InMemorySettingsStore()), dependencies: .inert)
        model.setup = .ready
        model.isOpen = true
        let folder = URL(fileURLWithPath: "/Users/Shared/Booth Fixtures", isDirectory: true)

        func doneJob(_ name: String, took: Double, music: Bool) -> Job {
            var job = Job(input: folder.appendingPathComponent(name), state: .done)
            let output = OutputNaming.outputURL(for: job.input) { _ in false }
            job.output = output
            job.progress = 1
            job.result = JobResult(output: output, took: took, music: music)
            return job
        }

        /// Snapshots can't draw a real video, so the picture is a stand-in poster (`VideoPreview`).
        func video(aspect: Double) -> PreviewVideo {
            PreviewVideo(url: folder.appendingPathComponent("interview-take3-enhanced.mp4"), aspect: aspect, duration: 109)
        }

        func showDone(_ job: Job, video: PreviewVideo? = nil, showVideo: Bool = false, mixOpen: Bool = false) {
            model.jobs = [job]
            model.focusID = job.id
            model.screen = .done
            model.playhead = 0.32
            model.previewVideo = video
            model.settings.showVideo = showVideo
            model.isMixOpen = mixOpen
        }

        func workingJob(_ name: String, progress: Double, realTotal: Double) -> Job {
            var job = Job(input: folder.appendingPathComponent(name), state: .working)
            job.progress = progress
            job.stageLabel = EngineStage.stage(at: progress, in: EngineStage.studio)?.label ?? ""
            job.eta = realTotal * (1 - progress)
            return job
        }

        switch fixture {
        case .idle:
            model.screen = .idle
        case .idleDropHover:
            model.screen = .idle
            model.dropHover = true
        case .firstrun:
            model.setup = .running(SetupProgressInfo(
                phase: "weights", label: "Downloading voice models",
                bytesDone: 412_000_000, bytesTotal: 1_130_000_000, eta: 110))
            model.screen = .firstrun
        case .firstrunWaiting:
            model.setup = .waitingForEngine(folder: "~/Documents/projects/booth")
            model.screen = .firstrun
        case .firstrunFailed:
            model.setup = .failed(message: "The download stopped before it finished. Check the connection and try again.")
            model.screen = .firstrun
        case .working:
            let active = workingJob(file, progress: progress, realTotal: 109)
            model.jobs = [
                active,
                Job(input: folder.appendingPathComponent("voice-memo.m4a")),
                Job(input: folder.appendingPathComponent("street-interview.mov")),
            ]
            model.activeID = active.id
            model.focusID = active.id
            model.screen = .working
        case .done:
            showDone(doneJob(file, took: 109, music: true), video: video(aspect: videoAspect))
        case .doneMix:
            showDone(doneJob(file, took: 109, music: true), video: video(aspect: 16 / 9), mixOpen: true)
        case .doneDirtyComparing:
            let done = doneJob(file, took: 109, music: true)
            showDone(done, video: video(aspect: 16 / 9), mixOpen: true)
            let background = workingJob("voice-memo.m4a", progress: 0.34, realTotal: 27)
            model.jobs.append(background)
            model.activeID = background.id
            model.mix = Mix(speech: 72, background: 28, music: 10)
            model.isComparing = true
        case .doneNoMusic:
            showDone(doneJob("voice-memo.m4a", took: 27, music: false), mixOpen: true)
        case .doneVideo:
            showDone(doneJob(file, took: 109, music: true), video: video(aspect: videoAspect), showVideo: true)
        case .doneVideoPortrait:
            showDone(doneJob(file, took: 109, music: true), video: video(aspect: 9 / 16), showVideo: true)
        case .doneVideoMix:
            showDone(
                doneJob(file, took: 109, music: true), video: video(aspect: 16 / 9), showVideo: true,
                mixOpen: true)
        case .doneDropHover:
            showDone(doneJob(file, took: 109, music: true), video: video(aspect: 16 / 9))
            model.dropHover = true
        case .settings:
            model.previousScreen = .idle
            model.screen = .settings
        case .error:
            model.error = .noAudio(fileName: "b-roll-silent.mov")
            model.errorFileName = "b-roll-silent.mov"
            model.screen = .error
        }
        return model
    }
}
