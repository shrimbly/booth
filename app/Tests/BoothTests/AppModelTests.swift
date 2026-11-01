import BoothCore
import Foundation
import Testing
@testable import Booth

/// A model wired to manual fakes, with handles to drive and inspect them.
@MainActor
struct Harness {
    let model: AppModel
    let runner = ManualJobRunner()
    let setupRunner = ManualSetupRunner()
    let player = RecordingPreviewPlayer()
    let notifier = RecordingNotifier()
    let loginItem = RecordingLoginItem()
    let workspace = RecordingWorkspace()
    let locator: StubEngineLocator
    let remixer = FakeRemixer(delay: .zero)
    let settings = Settings(store: InMemorySettingsStore())
    let clock: Clock

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    /// `remixing` replaces the instant `remixer` (saves that take time or fail); `video` reads
    /// done jobs' pictures (none by default).
    init(
        availability: EngineAvailability = .ready(.demo), remixing: Remixing? = nil,
        video: VideoInspecting = NoVideoInspector(), finishHold: Duration = .zero
    ) {
        locator = StubEngineLocator(availability: availability)
        let clock = Clock()
        self.clock = clock
        model = AppModel(
            settings: settings,
            dependencies: AppDependencies(
                engine: EngineServices(locator: locator, jobs: runner, setup: setupRunner, remixer: remixing ?? remixer, player: player),
                system: SystemServices(notifier: notifier, loginItem: loginItem, workspace: workspace, video: video)),
            stemsRoot: URL(fileURLWithPath: "/tmp/booth-tests/jobs", isDirectory: true),
            now: { clock.now },
            finishHold: finishHold)
    }

    /// A ready engine, as after launch.
    static func ready() async -> Harness {
        let harness = Harness()
        await harness.model.checkEngine()
        return harness
    }

    func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/booth-tests/in/\(name)")
    }

    /// The stems directory the model gives a job.
    func stems(_ id: Job.ID) -> URL {
        URL(fileURLWithPath: "/tmp/booth-tests/jobs/\(id.uuidString)", isDirectory: true)
    }

    /// A ready engine whose Working screen holds a finished job for `finishHold` before Done.
    static func ready(finishHold: Duration) async -> Harness {
        let harness = Harness(finishHold: finishHold)
        await harness.model.checkEngine()
        return harness
    }

    /// A ready engine, with `remixing` doing the saves.
    static func ready(remixing: Remixing) async -> Harness {
        let harness = Harness(remixing: remixing)
        await harness.model.checkEngine()
        return harness
    }

    /// A ready engine whose done jobs' files look like `video`.
    static func ready(video: VideoInspecting) async -> Harness {
        let harness = Harness(video: video)
        await harness.model.checkEngine()
        return harness
    }

    /// Runs the active job to completion.
    func finishActive(music: Bool = false) throws {
        let active = try #require(model.activeJob)
        let output = try #require(active.output)
        runner.send(.start(EngineStart(duration: 48, hasVideo: false, meta: "0:48 · WAV", eta: 27)), to: active.id)
        runner.send(.progress(EngineProgress(progress: 0.5, label: "Restoring the voice", eta: 12)), to: active.id)
        runner.send(.done(EngineDone(output: output.path, wav: output.path, took: 27, music: music, mix: .standard)), to: active.id)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@Suite("AppModel")
@MainActor
struct AppModelTests {
    @Test func startsCheckingThenBecomesReady() async {
        let h = Harness()
        #expect(h.model.setup == .checking)
        #expect(h.model.glyphMode == .idle)
        await h.model.checkEngine()
        #expect(h.model.setup == .ready)
        #expect(h.model.effectiveScreen == .idle)
    }

    @Test func launchAppliesPreferences() async throws {
        let h = Harness()
        h.model.launch()
        #expect(h.notifier.authorizationRequests == 1)
        #expect(h.loginItem.calls == [true])
        try await h.waitUntil { h.model.setup == .ready }
    }

    @Test func enqueueStartsTheFirstFileWithTheSettingsOptions() async throws {
        let h = await Harness.ready()
        h.settings.engine = .clean
        h.settings.noSplit = true
        h.model.open()
        let accepted = h.model.enqueue([h.file("notes.txt"), h.file("take.wav")])
        #expect(accepted.map(\.lastPathComponent) == ["take.wav"])
        #expect(h.model.pulse)

        let started = try #require(h.runner.started.first)
        #expect(started.job.input.lastPathComponent == "take.wav")
        #expect(started.options.output.path == "/tmp/booth-tests/in/take-enhanced.wav")
        #expect(started.options.stemsDirectory.lastPathComponent == started.job.id.uuidString)
        #expect(started.options.engine == .clean)
        #expect(!started.options.splitMusic)
        #expect(started.options.keepVideo)
        #expect(h.model.activeID == started.job.id)
        #expect(h.model.focusID == started.job.id)
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.glyphMode == .working)
    }

    @Test func onlyUnsupportedFilesOpenTheErrorScreen() async {
        let h = await Harness.ready()
        #expect(h.model.enqueue([h.file("a.pdf"), h.file("b.txt")]).isEmpty)
        #expect(h.model.jobs.isEmpty)
        #expect(!h.model.pulse)
        #expect(h.runner.started.isEmpty)
        #expect(h.model.isOpen)
        #expect(h.model.effectiveScreen == .error)
        #expect(h.model.error?.code == .decodeFailed)
        #expect(h.model.errorTitle == "Booth couldn't read these files")
        #expect(h.model.errorBody == "a.pdf and 1 more aren't audio or video files Booth can read. Nothing was changed.")
        #expect(h.model.errorFileName == "a.pdf")

        // A file Booth takes clears it.
        h.model.enqueue([h.file("take.au")])
        #expect(h.model.error == nil)
        #expect(h.model.effectiveScreen == .working)
    }

    @Test func oneUnsupportedFileIsNamed() async {
        let h = await Harness.ready()
        h.model.enqueue([h.file("clip.xyz")])
        #expect(h.model.errorTitle == "Booth couldn't read this file")
        #expect(h.model.errorBody == "clip.xyz isn't an audio or video file Booth can read. Nothing was changed.")
    }

    @Test func mixedInputQueuesTheSupportedFilesWithoutAnError() async {
        let h = await Harness.ready()
        h.model.open()
        let accepted = h.model.enqueue([h.file("notes.pdf"), h.file("ring.m4r"), h.file("clip.f4v")])
        #expect(accepted.map(\.lastPathComponent) == ["ring.m4r", "clip.f4v"])
        #expect(h.model.error == nil)
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.queuedJobs.map(\.name) == ["clip.f4v"])
    }

    @Test func rejectionsCanBeLeftToTheCaller() async {
        let h = await Harness.ready()
        #expect(h.model.enqueue([h.file("a.pdf")], reportingRejections: false).isEmpty)
        #expect(!h.model.isOpen)
        #expect(h.model.error == nil)
        #expect(h.model.effectiveScreen == .idle)
        // Nothing handed over (a cancelled chooser) is never an error.
        #expect(h.model.enqueue([]).isEmpty)
        #expect(h.model.error == nil)
    }

    @Test func busyBoothQueuesAndFinishingStartsTheNext() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav"), h.file("c.wav")])
        #expect(h.runner.started.count == 1)
        #expect(h.model.queuedJobs.map(\.name) == ["b.wav", "c.wav"])
        #expect(h.model.queueLine == "Next: b.wav and 1 more")

        let first = try #require(h.model.activeJob)
        h.runner.send(.progress(EngineProgress(progress: 0.52, label: "Restoring the voice", eta: 61)), to: first.id)
        #expect(h.model.statusLine == "52% · Restoring the voice · about 1 min left")
        #expect(h.model.glyphProgress == 0.52)

        try h.finishActive()
        // Watching the job finish switches to Done while the next one runs in the background.
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == first.id)
        #expect(h.model.activeJob?.name == "b.wav")
        #expect(h.model.backgroundJobLabel == "In the booth: b.wav · 0%")
        #expect(h.runner.started.count == 2)
        #expect(h.notifier.posted.isEmpty)

        h.model.switchToActive()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.displayedJob?.name == "b.wav")
    }

    @Test func filesFinishingBehindADoneScreenWaitForDone() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav"), h.file("c.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive()
        let b = try #require(h.model.activeJob)

        // b finishes while a's Done screen is in use: a stays on screen and b waits.
        try h.finishActive()
        let c = try #require(h.model.activeJob)
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == a.id)
        #expect(h.model.unseenIDs == [b.id])
        #expect(h.notifier.posted.isEmpty)

        // Done moves on to b, with c still in the booth.
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == b.id)
        #expect(h.player.loaded.last??.output == h.model.job(b.id)?.result?.output)
        #expect(h.model.backgroundJobLabel == "In the booth: c.wav · 0%")
        #expect(h.model.unseenIDs.isEmpty)

        // c finishes behind b's Done screen, and comes next.
        try h.finishActive()
        #expect(h.model.focusID == b.id)
        #expect(h.model.unseenIDs == [c.id])
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == c.id)
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .idle)
        #expect(h.model.unseenIDs.isEmpty)
        #expect(h.notifier.posted.isEmpty)
    }

    @Test func aFileWaitingToBeSeenIsShownOnTheNextOpen() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav"), h.file("c.wav")])
        try h.finishActive()
        let b = try #require(h.model.activeJob)
        try h.finishActive() // behind a's Done screen
        h.model.switchToActive()
        h.model.cancelActive()
        #expect(h.model.effectiveScreen == .idle)

        h.model.close()
        h.model.open()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == b.id)
        #expect(h.model.unseenIDs.isEmpty)
    }

    @Test func watchingAJobFinishHoldsWorkingAtFullThenShowsDone() async throws {
        let h = await Harness.ready(finishHold: .milliseconds(60))
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let first = try #require(h.model.activeJob)
        try h.finishActive()
        // The finished file stays on Working, full, while the next one starts behind it.
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.workingJob?.id == first.id)
        #expect(h.model.workingJob?.progress == 1)
        #expect(h.model.statusLine?.hasPrefix("100%") == true)
        #expect(h.model.activeJob?.name == "b.wav")
        // The × is drawn for the finished file, so it must not cancel the next one.
        h.model.cancelActive()
        #expect(h.model.activeJob?.name == "b.wav")
        #expect(h.runner.cancelled.isEmpty)

        try await h.waitUntil { h.model.effectiveScreen == .done }
        #expect(h.model.focusID == first.id)
        #expect(h.model.finishingID == nil)
        #expect(h.model.backgroundJobLabel == "In the booth: b.wav · 0%")
    }

    @Test func closingDuringTheFinishHoldReopensOnDone() async throws {
        let h = await Harness.ready(finishHold: .seconds(60))
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()
        #expect(h.model.effectiveScreen == .working)
        h.model.close()
        h.model.open()
        #expect(h.model.effectiveScreen == .done)
    }

    @Test func closingDuringTheFinishHoldWithAnotherFileKeepsTheJobForLater() async throws {
        let h = await Harness.ready(finishHold: .seconds(60))
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive()
        let b = try #require(h.model.activeJob)
        h.model.close()

        // b is in the booth, so the next open shows it; a hasn't had its Done screen yet.
        h.model.open()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.focusID == b.id)
        #expect(h.model.unseenIDs == [a.id])

        h.model.close()
        try h.finishActive()
        #expect(h.model.glyphMode == .done)
        #expect(h.notifier.posted.map(\.id) == [b.id])
        h.model.open()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == a.id)
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == b.id)
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .idle)
    }

    @Test func settingsDuringTheFinishHoldGoesBackToDone() async throws {
        let h = await Harness.ready(finishHold: .seconds(60))
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()
        h.model.showSettings()
        h.model.back()
        #expect(h.model.effectiveScreen == .done)
    }

    @Test func aNewFileDuringTheFinishHoldTakesOverAtOnce() async throws {
        let h = await Harness.ready(finishHold: .seconds(60))
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive()
        h.model.enqueue([h.file("b.wav")])
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.workingJob?.name == "b.wav")
        // a never reached its Done screen: it waits for one.
        #expect(h.model.unseenIDs == [a.id])
        h.model.close()
    }

    @Test func finishingWhileClosedFlagsTheIconAndNotifies() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("memo.m4a")])
        let job = try #require(h.model.activeJob)
        try h.finishActive(music: true)

        #expect(h.model.unseen)
        #expect(h.model.glyphMode == .done)
        #expect(h.notifier.posted.map(\.id) == [job.id])
        #expect(Formatting.notificationBody(name: h.notifier.posted[0].name) == "memo.m4a is out of the booth.")

        h.model.toggleOpen()
        #expect(h.model.isOpen)
        #expect(h.model.effectiveScreen == .done)
        #expect(!h.model.unseen)
        #expect(h.model.musicDetected)
        #expect(h.model.waveformLevels.count == 56)
        #expect(h.model.glyphMode == .idle)
    }

    @Test func filesFinishingWhileClosedAreShownInTurn() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive()
        let b = try #require(h.model.activeJob)
        try h.finishActive()
        #expect(h.notifier.posted.map(\.id) == [a.id, b.id])
        #expect(h.model.glyphMode == .done)

        h.model.open()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == a.id)
        // Reopening comes back to the Done screen left open; Done moves on.
        h.model.close()
        h.model.open()
        #expect(h.model.focusID == a.id)
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == b.id)
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .idle)
        #expect(h.model.unseenIDs.isEmpty)
    }

    @Test func openingDuringAJobShowsWorkingForTheActiveJob() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        try h.finishActive()
        // Closed: a.wav is unseen, but b.wav is running and wins.
        h.model.open()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.focusJob?.name == "b.wav")
    }

    @Test func notificationCompareOpensThatJob() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("a.wav")])
        let job = try #require(h.model.activeJob)
        try h.finishActive()
        h.notifier.onAction?(.compare, job.id)
        #expect(h.model.isOpen)
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == job.id)

        h.notifier.onAction?(.showInFinder, job.id)
        // The output does not exist on disk in tests, so the input is revealed.
        #expect(h.workspace.revealed.last == [job.input])
    }

    @Test func cancelStartsTheNextQueuedJob() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let first = try #require(h.model.activeJob)
        h.model.cancelActive()
        #expect(h.runner.cancelled == [first.id])
        #expect(h.model.job(first.id) == nil)
        #expect(h.model.activeJob?.name == "b.wav")
        #expect(h.model.focusJob?.name == "b.wav")
        #expect(h.model.effectiveScreen == .working)

        // The cancelled job's late events are ignored.
        h.runner.send(.error(JobError(code: .cancelled, message: "Cancelled.")), to: first.id)
        #expect(h.model.error == nil)

        h.model.cancelActive()
        #expect(h.model.activeID == nil)
        #expect(h.model.effectiveScreen == .idle)
    }

    /// The demo's runner reports `cancelled` from inside `cancel(jobID:)`; the next file must
    /// still become the tracked active job.
    @Test func cancelWithARunnerThatReportsAtOnceStillTracksTheNextJob() async throws {
        let runner = FakeJobRunner(timeScale: 100)
        let model = AppModel(
            settings: Settings(store: InMemorySettingsStore()),
            dependencies: AppDependencies(
                engine: EngineServices(
                    locator: StubEngineLocator(availability: .ready(.demo)), jobs: runner,
                    setup: ManualSetupRunner(), remixer: FakeRemixer(delay: .zero), player: RecordingPreviewPlayer()),
                system: .recording),
            stemsRoot: URL(fileURLWithPath: "/tmp/booth-tests/jobs", isDirectory: true))
        await model.checkEngine()
        model.open()
        model.enqueue([URL(fileURLWithPath: "/tmp/booth-tests/in/a.wav"), URL(fileURLWithPath: "/tmp/booth-tests/in/b.wav")])
        model.cancelActive()
        #expect(model.jobs.map(\.name) == ["b.wav"])
        #expect(model.activeJob?.name == "b.wav")
        #expect(model.activeJob?.state == .working)
        #expect(model.focusJob?.name == "b.wav")
        #expect(model.effectiveScreen == .working)
        #expect(model.error == nil)
        runner.cancelAll()
    }

    @Test func instantNoAudioErrorOpensTheErrorScreen() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("b-roll-silent.mov")])
        let job = try #require(h.model.activeJob)
        h.runner.send(.error(.noAudio(fileName: job.name)), to: job.id)
        #expect(h.model.isOpen)
        #expect(h.model.effectiveScreen == .error)
        #expect(h.model.errorTitle == "This file has no audio")
        #expect(h.model.errorBody == "b-roll-silent.mov has a video track but no sound. Nothing was changed.")
        #expect(h.model.errorFileName == "b-roll-silent.mov")
        #expect(h.model.jobs.isEmpty)
        #expect(h.model.activeID == nil)

        h.model.dismissError()
        #expect(h.model.error == nil)
        #expect(h.model.effectiveScreen == .idle)
    }

    @Test func lateFailureWhileClosedOnlyFlagsTheIcon() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("long.wav"), h.file("next.wav")])
        let job = try #require(h.model.activeJob)
        h.clock.now += 60
        h.runner.send(.error(JobError(code: .engineFailed, message: "Sidon crashed.\nTraceback…")), to: job.id)
        #expect(!h.model.isOpen)
        #expect(h.model.glyphMode == .attention)
        #expect(h.model.activeJob?.name == "next.wav")

        h.model.open()
        #expect(h.model.effectiveScreen == .error)
        #expect(h.model.errorTitle == "Something went wrong")
        #expect(h.model.errorBody == "Sidon crashed.")
        // A new file clears the error.
        h.model.enqueue([h.file("third.wav")])
        #expect(h.model.error == nil)
    }

    @Test func chooseAnotherDismissesAndOpensThePanel() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("silent.mov")])
        let job = try #require(h.model.activeJob)
        h.runner.send(.error(.noAudio(fileName: job.name)), to: job.id)
        h.workspace.nextChoice = [h.file("good.wav")]
        h.model.chooseAnother()
        #expect(h.model.error == nil)
        #expect(h.model.activeJob?.name == "good.wav")
        #expect(h.model.effectiveScreen == .working)
    }

    /// One bad file in a batch: the Error screen, then Working for the next file.
    func failFirstOfBatch(_ h: Harness) throws -> Job {
        h.model.open()
        h.model.enqueue([h.file("silent.mov"), h.file("talk.wav")])
        let silent = try #require(h.model.activeJob)
        h.runner.send(.error(.noAudio(fileName: silent.name)), to: silent.id)
        #expect(h.model.effectiveScreen == .error)
        #expect(h.model.focusID == nil)
        return try #require(h.model.activeJob)
    }

    @Test func dismissingAnErrorFocusesTheFileInTheBooth() async throws {
        let h = await Harness.ready()
        let talk = try failFirstOfBatch(h)
        h.model.dismissError()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.focusID == talk.id)

        try h.finishActive()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == talk.id)
        #expect(h.model.unseenIDs.isEmpty)
    }

    @Test func aDropOnTheErrorScreenWhileBusyFocusesTheFileInTheBooth() async throws {
        let h = await Harness.ready()
        let talk = try failFirstOfBatch(h)
        h.model.enqueue([h.file("more.wav")])
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.focusID == talk.id)

        try h.finishActive()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == talk.id)
        #expect(h.model.backgroundJobLabel == "In the booth: more.wav · 0%")
    }

    @Test func aFileFinishingBehindTheErrorScreenIsShownOnDismiss() async throws {
        let h = await Harness.ready()
        let talk = try failFirstOfBatch(h)
        try h.finishActive()
        #expect(h.model.effectiveScreen == .error)
        #expect(h.model.unseenIDs == [talk.id])
        #expect(h.notifier.posted.isEmpty)

        h.model.dismissError()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == talk.id)
        #expect(h.model.unseenIDs.isEmpty)
    }

    @Test func chooseAnotherKeepsAFileWaitingToBeSeen() async throws {
        let h = await Harness.ready()
        let talk = try failFirstOfBatch(h)
        try h.finishActive()
        #expect(h.model.unseenIDs == [talk.id])

        h.workspace.nextChoice = [h.file("more.wav")]
        h.model.chooseAnother()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.unseenIDs == [talk.id])
    }

    @Test func settingsAndBack() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        h.model.showSettings()
        #expect(h.model.effectiveScreen == .settings)
        #expect(!h.model.acceptsDrops)
        h.model.showSettings()
        h.model.back()
        #expect(h.model.effectiveScreen == .working)

        h.model.setOpenAtLogin(false)
        #expect(h.loginItem.calls == [false])
        #expect(!h.settings.openAtLogin)
        h.model.setEngine(.quick)
        h.model.setKeepVideo(false)
        h.model.setNoSplit(true)
        #expect(h.settings.engine == .quick && !h.settings.keepVideo && h.settings.noSplit)
    }

    @Test func aFileFinishingBehindSettingsIsShownOnBack() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let a = try #require(h.model.activeJob)
        h.model.showSettings()
        try h.finishActive()
        let b = try #require(h.model.activeJob)
        #expect(h.model.effectiveScreen == .settings)

        // As if Working had been watched: a's Done screen, with b in the booth.
        h.model.back()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == a.id)
        #expect(h.model.backgroundJobLabel == "In the booth: b.wav · 0%")
        #expect(h.model.unseenIDs.isEmpty)

        h.model.closeDone()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.focusID == b.id)
        try h.finishActive()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == b.id)
    }

    @Test func aFileFinishingBehindSettingsOverADoneScreenWaitsForDone() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive()
        let b = try #require(h.model.activeJob)
        h.model.showSettings()
        try h.finishActive()
        #expect(h.model.unseenIDs == [b.id])

        h.model.back()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == a.id)
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == b.id)
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .idle)
    }

    @Test func onlyJobsStillInReachKeepTheirStems() async throws {
        let remixer = ControlledRemixer()
        let h = await Harness.ready(remixing: remixer)
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav"), h.file("c.wav"), h.file("d.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive() // a's Done screen
        let b = try #require(h.model.activeJob)
        try h.finishActive() // behind a's Done screen: b waits
        let c = try #require(h.model.activeJob)
        let d = try #require(h.model.queuedJobs.first)
        let atC = try #require(h.runner.prunes.last)
        #expect(Set([a.id, b.id, c.id, d.id].map(h.stems)).isSubset(of: atC.protecting))

        // Done moves on to b, and b's Save starts. a's Done screen is out of reach now.
        h.model.closeDone()
        h.model.setMix(Mix(speech: 70, background: 20, music: 0))
        h.model.saveMix()
        try await h.waitUntil { remixer.pending.count == 1 }
        try h.finishActive() // c, behind b's Done screen
        let atD = try #require(h.runner.prunes.last)
        #expect(!atD.protecting.contains(h.stems(a.id)))
        #expect(Set([b.id, c.id, d.id].map(h.stems)).isSubset(of: atD.protecting))

        // Off screen, b keeps its stems only while its Save runs.
        h.model.closeDone() // c
        h.model.closeDone() // Working: d
        try h.finishActive()
        h.model.enqueue([h.file("e.wav"), h.file("f.wav")])
        let e = try #require(h.model.activeJob)
        let atE = try #require(h.runner.prunes.last)
        #expect(atE.protecting.contains(h.stems(b.id)))
        #expect(!atE.protecting.contains(h.stems(a.id)) && !atE.protecting.contains(h.stems(c.id)))
        remixer.succeed(0)
        try await h.waitUntil { h.model.savingJobs.isEmpty }
        try h.finishActive() // e; f starts
        let atF = try #require(h.runner.prunes.last)
        #expect(h.runner.prunes.count == 6) // one per start
        #expect(atF.root.path == "/tmp/booth-tests/jobs")
        #expect(!atF.protecting.contains(h.stems(b.id)))
        #expect(atF.protecting.contains(h.stems(e.id)))
    }

    @Test func unseenJobsKeepTheirStemsUpToALimit() async throws {
        let h = await Harness.ready()
        var finished: [Job.ID] = []
        for i in 1...(AppModel.unseenLimit + 2) { // one file after another while closed, none looked at
            h.model.enqueue([h.file("take\(i).wav")])
            finished.append(try #require(h.model.activeJob).id)
            try h.finishActive()
        }
        // At the last start, the eleven before it were waiting; only the newest ten still are.
        let last = try #require(h.runner.prunes.last)
        #expect(!last.protecting.contains(h.stems(finished[0])))
        #expect(finished.dropFirst().allSatisfy { last.protecting.contains(h.stems($0)) })
        #expect(h.model.unseenIDs == Array(finished.suffix(AppModel.unseenLimit)))

        h.model.open()
        #expect(h.model.focusID == finished[2])
    }

    @Test func secondJobForTheSameFileGetsTheNextName() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("a.wav"), h.file("a.wav")])
        try h.finishActive()
        #expect(h.runner.started.map(\.options.output.lastPathComponent) == ["a-enhanced.wav", "a-enhanced 2.wav"])
    }

    @Test func firstRunSetupQueuesFilesUntilReady() async throws {
        let h = Harness(availability: .needsSetup(nil))
        await h.model.checkEngine()
        #expect(h.setupRunner.startCount == 1)
        #expect(h.model.setup.isRunning)
        #expect(h.model.glyphMode == .working)

        h.model.open()
        #expect(h.model.effectiveScreen == .firstrun)
        h.setupRunner.send(.setup(SetupProgress(bytesDone: 412_000_000, bytesTotal: 1_130_000_000, eta: 110)))
        #expect(h.model.setupBytesText == "412 MB of 1.13 GB")
        #expect(h.model.setupTimeLeftText == "about 2 min left")

        h.model.runSetupInBackground()
        #expect(!h.model.isOpen)
        h.model.enqueue([h.file("a.wav")])
        #expect(h.runner.started.isEmpty)
        #expect(h.model.queuedJobs.count == 1)

        h.setupRunner.send(.done(EngineDone()))
        #expect(h.model.setup == .ready)
        #expect(h.runner.started.count == 1)
        #expect(h.model.activeJob?.name == "a.wav")
    }

    /// After a first launch, setup is all Booth has to show, so the popover opens on it. A launch
    /// with the engine ready stays in the menu bar.
    @Test func setupOpensThePopoverAtLaunch() async throws {
        let ready = await Harness.ready()
        #expect(!ready.model.isOpen)

        let firstRun = Harness(availability: .needsSetup(nil))
        await firstRun.model.checkEngine()
        #expect(firstRun.model.isOpen)
        #expect(firstRun.model.effectiveScreen == .firstrun)

        let silent = Harness(availability: .unresponsive(EngineCandidate(path: "/Users/someone/sv/.venv/bin/booth", source: .launchArgument)))
        await silent.model.checkEngine()
        #expect(silent.model.isOpen)
        #expect(silent.model.effectiveScreen == .firstrun)
    }

    @Test func setupFailureAndRetry() async throws {
        let h = Harness(availability: .needsSetup(nil))
        await h.model.checkEngine()
        // Dismissed while setup runs: a failure lights the icon.
        h.model.close()
        h.setupRunner.send(.error(JobError(code: .setupFailed, message: "No internet.")))
        #expect(h.model.setupFailureMessage == "No internet.")
        #expect(h.model.glyphMode == .attention)
        h.model.open()
        #expect(h.model.effectiveScreen == .firstrun)
        h.model.retrySetup()
        #expect(h.setupRunner.startCount == 2)
        #expect(h.model.setup.isRunning)
        h.setupRunner.send(.done(EngineDone()))
        #expect(h.model.effectiveScreen == .idle)
    }

    @Test func anUnresponsiveEngineFailsSetupAndTryAgainAsksItAgain() async throws {
        let candidate = EngineCandidate(path: "/Users/someone/Documents/sv/.venv/bin/booth", source: .launchArgument)
        let h = Harness(availability: .unresponsive(candidate))
        await h.model.checkEngine()
        let folder = AppModel.engineFolder(candidate)
        #expect(h.model.setup == .failed(message: Formatting.engineUnresponsiveMessage(folder: folder)))
        #expect(h.model.setupFailureMessage?.hasSuffix("choose Allow, then click Try again.") == true)
        #expect(h.setupRunner.startCount == 0)
        #expect(h.model.effectiveScreen == .firstrun)
        // Dismissed, the icon carries the failure.
        h.model.close()
        #expect(h.model.glyphMode == .attention)
        h.model.open()
        #expect(h.model.effectiveScreen == .firstrun)
        h.model.enqueue([h.file("a.wav")]) // still queues
        #expect(h.model.queuedJobs.count == 1)

        // Try again: still silent. The engine is asked again; setup never runs.
        h.locator.holdsAnswer = true
        h.model.retrySetup()
        #expect(h.model.setup == .waitingForEngine(folder: folder)) // while it is asked again
        #expect(h.model.setupWaitingText == Formatting.engineWaitingBody(folder: folder))
        try await h.waitUntil { h.locator.locateCount == 2 }
        h.locator.answer()
        try await h.waitUntil { h.model.setup.isFailed }
        #expect(h.setupRunner.startCount == 0)

        // Try again after choosing Allow: it answers, and the queued file starts.
        h.locator.availability = .ready(.demo)
        h.model.retrySetup()
        try await h.waitUntil { h.model.setup == .ready }
        #expect(h.locator.locateCount == 3)
        #expect(h.setupRunner.startCount == 0)
        #expect(h.model.activeJob?.name == "a.wav")
    }

    @Test func aSlowEngineShowsWaitingThenSetsUp() async throws {
        let candidate = EngineCandidate(path: "/opt/sv/.venv/bin/booth", source: .environment)
        let h = Harness(availability: .needsSetup(nil))
        h.locator.waitingOn = candidate
        h.locator.holdsAnswer = true
        let checking = Task { await h.model.checkEngine() }
        try await h.waitUntil { h.model.setup.isWaitingForEngine }
        #expect(h.model.setup == .waitingForEngine(folder: "/opt/sv"))
        #expect(h.model.glyphMode == .working)
        #expect(h.model.glyphProgress == 0)
        h.locator.answer()
        await checking.value
        // A real "nothing found" (every candidate absent or broken) still sets up.
        #expect(h.setupRunner.startCount == 1)
        #expect(h.model.setup.isRunning)
        #expect(h.model.setupWaitingText == nil)
    }

    @Test func theDemoCanSimulateASlowEngine() async throws {
        let model = AppModel(
            settings: Settings(store: InMemorySettingsStore()),
            dependencies: AppDependencies(engine: .demo(environment: ["BOOTH_DEMO_ENGINE_WAIT": "0.3"]), system: .recording),
            stemsRoot: URL(fileURLWithPath: "/tmp/booth-tests/jobs", isDirectory: true))
        let checking = Task { await model.checkEngine() }
        for _ in 0..<100 where !model.setup.isWaitingForEngine { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.setupWaitingText?.contains("/Documents/booth is taking a while to start") == true)
        await checking.value
        #expect(model.setup == .ready)
    }

    @Test func aSetupFailureStillRetriesSetup() async throws {
        let h = Harness(availability: .needsSetup(nil))
        await h.model.checkEngine()
        h.setupRunner.send(.error(JobError(code: .setupFailed, message: "No internet.")))
        h.model.retrySetup()
        #expect(h.setupRunner.startCount == 2)
        #expect(h.locator.locateCount == 1)
    }

    @Test func setupRequiredRequeuesTheFile() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("a.wav")])
        let job = try #require(h.model.activeJob)
        h.runner.send(.error(JobError(code: .setupRequired, message: "Models missing.")), to: job.id)
        #expect(h.model.error == nil)
        #expect(h.model.setup.isRunning)
        #expect(h.model.queuedJobs.map(\.name) == ["a.wav"])
        h.setupRunner.send(.done(EngineDone()))
        #expect(h.runner.started.count == 2)
    }

    @Test func mixEditingRevertAndSave() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        let job = try #require(h.model.activeJob)
        try h.finishActive(music: true)
        #expect(h.player.loaded.last??.output == h.model.focusJob?.result?.output)

        let standardLevels = h.model.waveformLevels
        h.model.setMix(Mix(speech: 54, background: 90, music: 10))
        #expect(h.model.isMixDirty)
        #expect(abs((h.player.gains.last?.background ?? 0) - 0.81) < 1e-12)
        #expect(h.model.waveformLevels != standardLevels)

        h.model.revertMix()
        #expect(!h.model.isMixDirty)

        h.model.setMix(Mix(speech: 70, background: 20, music: 0))
        h.model.saveMix()
        #expect(h.model.isSaving)
        try await h.waitUntil { !h.model.isSaving }
        #expect(!h.model.isMixDirty)
        #expect(h.model.savedMix == Mix(speech: 70, background: 20, music: 0))
        #expect(h.model.job(job.id)?.result?.mix == Mix(speech: 70, background: 20, music: 0))
        #expect(h.remixer.requests.map(\.mix) == [Mix(speech: 70, background: 20, music: 0)])
    }

    @Test func playbackFollowsThePlayerAndStopsOnClose() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()

        h.model.togglePlay()
        #expect(h.model.isPlaying)
        #expect(h.player.playCount == 1)
        h.player.onStatusChange?(PlaybackStatus(isPlaying: true, playhead: 0.4))
        #expect(h.model.playhead == 0.4)
        h.model.seek(to: 1.5)
        #expect(h.player.seeks.last == 1)
        let resets = h.player.comparing.count // every focus change resets the player's compare
        #expect(h.player.comparing.allSatisfy { !$0 })
        h.model.setComparing(true)
        #expect(Array(h.player.comparing.dropFirst(resets)) == [true])

        h.model.close()
        #expect(!h.model.isPlaying)
        #expect(!h.model.isComparing)
        #expect(Array(h.player.comparing.dropFirst(resets)) == [true, false])
    }

    @Test func playWorksWhenTheJobFinishedBehindSettings() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        #expect(h.player.loaded.last! == nil) // still working: nothing to play yet
        h.model.showSettings()
        try h.finishActive()
        #expect(h.model.effectiveScreen == .settings)
        h.model.back()
        #expect(h.model.effectiveScreen == .done)

        h.model.togglePlay()
        let loaded = try #require(h.player.loaded.last)
        #expect(loaded?.output == h.model.focusJob?.result?.output)
        #expect(loaded != nil)
        #expect(h.player.playCount == 1)
        #expect(h.player.calls.last == "play")
        #expect(h.player.calls.lastIndex(of: "load") ?? .max < h.player.calls.lastIndex(of: "play") ?? -1)
    }

    @Test func aFailureWhileListeningStopsPlaybackAndReturnsToDone() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive()
        #expect(h.model.effectiveScreen == .done)
        h.model.togglePlay()
        h.model.setComparing(true)
        #expect(h.model.isPlaying)
        let pauses = h.player.pauseCount

        let b = try #require(h.model.activeJob)
        h.clock.now += 60
        h.runner.send(.error(JobError(code: .decodeFailed, message: "b.wav may be damaged.")), to: b.id)
        #expect(h.model.effectiveScreen == .error)
        #expect(!h.model.isPlaying)
        #expect(!h.model.isComparing)
        #expect(h.player.pauseCount == pauses + 1)
        #expect(h.player.comparing.last == false)

        h.model.dismissError()
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.focusID == a.id)
    }

    @Test func dismissingAnErrorWithoutAFinishedJobGoesIdle() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        let a = try #require(h.model.activeJob)
        h.runner.send(.error(JobError(code: .decodeFailed, message: "x")), to: a.id)
        h.model.dismissError()
        #expect(h.model.effectiveScreen == .idle)
    }

    @Test func aFocusChangeWithOptionHeldResetsThePlayersCompare() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()
        h.model.setComparing(true)
        #expect(h.player.comparing.last == true)
        // A file dropped with ⌥ held (Finder's copy-drag) on the idle booth takes the focus.
        h.model.enqueue([h.file("b.wav")])
        #expect(h.model.focusJob?.name == "b.wav")
        #expect(!h.model.isComparing)
        #expect(h.player.comparing.last == false)
        // The ⌥ release that follows is a no-op for the model and must not matter.
        h.model.setComparing(false)
        #expect(h.player.comparing.last == false)
    }

    @Test func savesArePerJob() async throws {
        let remixer = ControlledRemixer()
        let h = await Harness.ready(remixing: remixer)
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let a = try #require(h.model.activeJob)
        try h.finishActive()
        let b = try #require(h.model.activeJob)
        h.model.setMix(Mix(speech: 70, background: 20, music: 0))
        h.model.saveMix()
        #expect(h.model.isSaving)
        try await h.waitUntil { remixer.pending.count == 1 }

        // b finishes and is opened while a's save is still running.
        try h.finishActive()
        h.model.openJob(b.id)
        #expect(h.model.focusID == b.id)
        #expect(!h.model.isSaving)
        #expect(h.model.savingJobs == [a.id])
        h.model.setMix(Mix(speech: 30, background: 10, music: 10))
        h.model.saveMix() // not blocked by a's save
        try await h.waitUntil { remixer.pending.count == 2 }
        #expect(h.model.isSaving)

        // a's save fails while b is on screen: Done stays, but the failure is kept and flagged.
        remixer.fail(0, with: JobError(code: .engineFailed, message: "disk full"))
        try await h.waitUntil { h.model.error != nil }
        #expect(h.model.error?.message == "The new mix for a.wav wasn't saved. Its file still has the previous mix.")
        #expect(h.model.errorFileName == "a.wav")
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.saveError == nil) // b's own Save is fine
        #expect(h.model.saveErrors[a.id]?.message == "disk full")
        #expect(h.model.isSaving)
        h.model.close()
        #expect(h.model.glyphMode == .attention)
        h.model.open()
        #expect(h.model.effectiveScreen == .error)

        remixer.succeed(1)
        try await h.waitUntil { h.model.savingJobs.isEmpty }
        #expect(h.model.job(b.id)?.result?.mix == Mix(speech: 30, background: 10, music: 10))
    }

    @Test func aBackgroundSaveFailureOverWorkingShowsTheErrorScreen() async throws {
        let remixer = ControlledRemixer()
        let h = await Harness.ready(remixing: remixer)
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        try h.finishActive()
        h.model.setMix(Mix(speech: 70, background: 20, music: 0))
        h.model.saveMix()
        try await h.waitUntil { remixer.pending.count == 1 }
        h.model.switchToActive()
        #expect(h.model.effectiveScreen == .working)
        remixer.fail(0, with: JobError(code: .engineFailed, message: "boom"))
        try await h.waitUntil { h.model.error != nil }
        #expect(h.model.effectiveScreen == .error)
        h.model.dismissError()
        #expect(h.model.effectiveScreen == .working)
    }

    @Test func aFailedSaveOnScreenSaysTryAgain() async throws {
        let remixer = ControlledRemixer()
        let h = await Harness.ready(remixing: remixer)
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()
        h.model.setMix(Mix(speech: 70, background: 20, music: 0))
        h.model.saveMix()
        try await h.waitUntil { remixer.pending.count == 1 }
        remixer.fail(0, with: JobError(code: .engineFailed, message: "boom"))
        try await h.waitUntil { !h.model.isSaving }
        #expect(h.model.saveError?.message == "boom")
        #expect(h.model.error == nil) // its own Done screen says it
        #expect(h.model.effectiveScreen == .done)
    }

    @Test func dropHoverIsClearedOnClose() async {
        let h = await Harness.ready()
        h.model.open()
        h.model.dropHover = true
        h.model.close()
        #expect(!h.model.dropHover)
    }

    @Test func iconTargetDrivesTheGlyph() async {
        let h = await Harness.ready()
        h.model.iconTarget = true
        #expect(h.model.glyphMode == .target)
    }

    @Test func pulseEndsAfterAMoment() async throws {
        let h = await Harness.ready()
        h.model.triggerPulse()
        #expect(h.model.pulse)
        try await h.waitUntil { !h.model.pulse }
    }

    @Test func quitCancelsEverythingOnce() async throws {
        let h = await Harness.ready()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        let active = try #require(h.model.activeJob)
        h.model.quit()
        h.model.shutdown()
        #expect(h.runner.cancelAllCount == 1)
        #expect(h.workspace.terminateCount == 1)

        // The runner's cancellation must not start the queued file on the way out.
        h.runner.send(.error(JobError(code: .cancelled, message: "Cancelled.")), to: active.id)
        #expect(h.runner.started.count == 1)
        #expect(h.model.activeID == nil)
    }

    @Test(arguments: AppModel.Fixture.allCases)
    func fixturesShowTheirScreen(fixture: AppModel.Fixture) {
        let model = AppModel.fixture(fixture)
        #expect(model.isOpen)
        #expect(model.effectiveScreen == fixture.expectedScreen)
    }

    @Test func fixtureDetails() {
        let working = AppModel.fixture(.working)
        #expect(working.statusLine == "48% · Restoring the voice · about 1 min left")
        #expect(working.queueLine == "Next: voice-memo.m4a and 1 more")

        let dirty = AppModel.fixture(.doneDirtyComparing)
        #expect(dirty.isMixDirty && dirty.isComparing)
        #expect(dirty.backgroundJobLabel == "In the booth: voice-memo.m4a · 34%")
        #expect(!AppModel.fixture(.doneNoMusic).musicDetected)
        #expect(AppModel.fixture(.firstrun).setupBytesText == "412 MB of 1.13 GB")
        let waiting = AppModel.fixture(.firstrunWaiting)
        #expect(AppModel.Fixture.firstrunWaiting.rawValue == "firstrun-waiting")
        #expect(waiting.setupWaitingText == "Booth's engine in ~/Documents/projects/booth is taking a while to start. If macOS is asking whether Booth may access that folder, choose Allow.")
        #expect(waiting.setupFailureMessage == nil && waiting.setupBytesText == nil)
        #expect(AppModel.fixture(.idleDropHover).dropHover)
    }
}

/// A remixer whose saves end when the test says so.
@MainActor
final class ControlledRemixer: Remixing {
    private(set) var pending: [(result: JobResult, mix: Mix, continuation: CheckedContinuation<EngineDone, Error>?)] = []

    func remix(_ result: JobResult, to mix: Mix) async throws -> EngineDone {
        try await withCheckedThrowingContinuation { continuation in
            pending.append((result, mix, continuation))
        }
    }

    func succeed(_ index: Int) {
        let request = pending[index]
        pending[index].continuation = nil
        request.continuation?.resume(returning: EngineDone(output: request.result.output.path, took: 1, music: false, mix: request.mix))
    }

    func fail(_ index: Int, with error: JobError) {
        pending[index].continuation?.resume(throwing: error)
        pending[index].continuation = nil
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = Settings(store: InMemorySettingsStore())
        #expect(settings.engine == .studio)
        #expect(settings.keepVideo)
        #expect(!settings.noSplit)
        #expect(settings.openAtLogin)
        #expect(settings.enginePath == nil)
    }

    @Test func persistsAndReloads() {
        let store = InMemorySettingsStore()
        let settings = Settings(store: store)
        settings.engine = .quick
        settings.keepVideo = false
        settings.noSplit = true
        settings.openAtLogin = false
        settings.enginePath = "/opt/sv"
        #expect(store.object(forKey: "engine") as? String == "quick")

        let reloaded = Settings(store: store)
        #expect(reloaded.engine == .quick)
        #expect(!reloaded.keepVideo)
        #expect(reloaded.noSplit)
        #expect(!reloaded.openAtLogin)
        #expect(reloaded.enginePath == "/opt/sv")

        reloaded.enginePath = ""
        #expect(store.object(forKey: "enginePath") == nil)

        Settings.resetStoredValues(in: store)
        #expect(Settings(store: store).engine == .studio)
    }

    @Test func runOptionsReflectPreferences() {
        let settings = Settings(store: InMemorySettingsStore())
        settings.keepVideo = false
        let options = settings.runOptions(output: URL(fileURLWithPath: "/o.wav"), stemsDirectory: URL(fileURLWithPath: "/s"))
        #expect(!options.keepVideo && options.splitMusic && options.engine == .studio && options.mix == .standard)
    }
}

@Suite("Fake job runner")
@MainActor
struct FakeJobRunnerTests {
    func run(_ name: String, keepVideo: Bool = true) async throws -> [EngineEvent] {
        let runner = FakeJobRunner(timeScale: 0.01)
        let job = Job(input: URL(fileURLWithPath: "/tmp/\(name)"))
        let output = OutputNaming.outputURL(for: job.input, keepVideo: keepVideo) { _ in false }
        var events: [EngineEvent] = []
        runner.start(job: job, options: RunOptions(output: output, stemsDirectory: URL(fileURLWithPath: "/tmp/s"), keepVideo: keepVideo)) { events.append($0) }
        for _ in 0..<600 {
            if case .done = events.last { break }
            if case .error = events.last { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        return events
    }

    @Test func simulatesAFullRun() async throws {
        let events = try await run("interview-take3.mp4")
        guard case .hello = events.first, case .start(let start) = events[1], case .done(let done) = events.last else {
            Issue.record("unexpected stream \(events.prefix(2)) … \(String(describing: events.last))")
            return
        }
        #expect(start.meta == "3:12 · MP4 · 1080p")
        #expect(done.output?.hasSuffix("interview-take3-enhanced.mp4") == true)
        #expect(done.wav?.hasSuffix("interview-take3-enhanced.wav") == true)
        #expect(done.video == done.output)
        #expect(!done.music)

        let progress = events.compactMap { event -> EngineProgress? in
            if case .progress(let p) = event { return p }
            return nil
        }
        #expect(progress.count > 20)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.progress <= $1.progress })
        #expect(Set(progress.compactMap(\.label)) == Set(EngineStage.studio.map(\.label)))
    }

    @Test func fileNamesSteerTheOutcome() async throws {
        #expect(try await run("b-roll-silent.mov").last == .error(.noAudio(fileName: "b-roll-silent.mov")))
        if case .error(let error) = try await run("corrupt.wav").last {
            #expect(error.code == .decodeFailed)
            #expect(error.message == "corrupt.wav may be damaged or in a format Booth doesn't support. Nothing was changed.")
            #expect(Formatting.errorBody(for: error) == error.message)
        } else {
            Issue.record("expected decode_failed")
        }
        if case .done(let done) = try await run("mus_in.wav").last {
            #expect(done.music)
            #expect(done.video == nil)
        } else {
            Issue.record("expected done")
        }
    }

    @Test func cancelEndsWithCancelled() async throws {
        let runner = FakeJobRunner(timeScale: 1)
        let job = Job(input: URL(fileURLWithPath: "/tmp/a.wav"))
        var events: [EngineEvent] = []
        runner.start(job: job, options: RunOptions(output: URL(fileURLWithPath: "/tmp/a-enhanced.wav"), stemsDirectory: URL(fileURLWithPath: "/tmp/s"))) { events.append($0) }
        runner.cancel(jobID: job.id)
        #expect(events.last == .error(JobError(code: .cancelled, message: "Cancelled.")))
        try await Task.sleep(for: .milliseconds(700))
        #expect(events.count == 1)
    }

    @Test func demoDurationsStayInRange() {
        for name in ["a.wav", "interview-take3.mp4", "voice-memo.m4a", "x", ""] {
            #expect((6...11).contains(FakeJobRunner.demoSeconds(for: name)))
        }
    }
}
