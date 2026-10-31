import BoothCore
import Foundation
import Testing
@testable import Booth

/// A throwaway engine: a shell script that speaks just enough of protocol 1. The input file's
/// name picks the behaviour (see `script`).
@MainActor
final class ScriptEngine {
    let directory: URL
    let executable: URL

    /// app-info answers with `protocolVersion` and `ready` (true anyway once `setup` has run);
    /// `appInfoDelay` makes it slow, and `appInfoAnswers: false` makes it exit without an answer.
    init(protocolVersion: Int = 1, ready: Bool = true, appInfoDelay: Double = 0, appInfoAnswers: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("booth-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("booth")
        try Self.install(
            Self.script(protocolVersion: protocolVersion, ready: ready, appInfoDelay: appInfoDelay, appInfoAnswers: appInfoAnswers),
            at: executable)
    }

    /// Writes an executable script.
    static func install(_ script: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The commands this engine ran, in order.
    var calls: [String] {
        let log = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func input(_ name: String) -> URL { directory.appendingPathComponent(name) }
    var stemsRoot: URL { directory.appendingPathComponent("jobs", isDirectory: true) }

    /// A locator that only knows this engine (no login shell; this folder is its home, so the
    /// managed install and `~/.local/bin` candidates live in it too).
    func locator(validationTimeout: TimeInterval = 5, responseTimeout: TimeInterval = 180) -> EngineLocator {
        EngineLocator(
            toolchain: toolchain, launchArgument: executable.path, storedPreference: { nil }, environment: [:],
            infoPlistPath: nil, validationTimeout: validationTimeout, responseTimeout: responseTimeout)
    }

    var toolchain: EngineToolchain {
        EngineToolchain(home: directory, baseEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": "/usr/bin/false"], toolDirectories: [])
    }

    static func script(protocolVersion: Int = 1, ready: Bool = true, appInfoDelay: Double = 0, appInfoAnswers: Bool = true) -> String {
        """
        #!/bin/sh
        # Records every invocation so tests can count them.
        dir="$(dirname "$0")"
        echo "$1" >> "$dir/calls.log"
        case "$1" in
        app-info)
          # Its own stdout closed, so a SIGTERM leaves nothing holding the pipe.
          sleep \(appInfoDelay) >/dev/null 2>&1
          \(appInfoAnswers ? "" : "exit 0")
          ready=\(ready)
          [ -f "$dir/models-ready" ] && ready=true
          echo '{"event":"info","protocol":\(protocolVersion),"version":"9.9","engines":["sidon"],"ready":'$ready',"missing":["sidon-weights"]}'
          exit 0 ;;
        setup)
          echo '{"event":"setup","phase":"weights","label":"Downloading voice models","bytes_done":1,"bytes_total":2}'
          touch "$dir/models-ready"
          echo '{"event":"done"}'
          exit 0 ;;
        remix)
          echo '{"event":"hello","protocol":1,"version":"9.9"}'
          echo '{"event":"done","output":"/tmp/out.wav","took":0.1,"music":false,"mix":{"speech":70,"background":20,"music":5}}'
          exit 0 ;;
        enhance) ;;
        *) echo "unknown command $1" >&2; exit 64 ;;
        esac
        name=$(basename "$2")
        echo "cwd $(pwd)" >&2
        echo '{"event":"hello","protocol":1,"version":"9.9"}'
        case "$name" in
        crash*)
          echo 'Traceback (most recent call last):' >&2
          echo '  File "x.py", line 1' >&2
          echo 'RuntimeError: boom' >&2
          exit 1 ;;
        silent*) exit 0 ;;
        refuse*)
          echo '{"event":"error","code":"no_audio","message":"refuse.mov has a video track but no sound. Nothing was changed."}'
          exit 2 ;;
        slow*)
          trap 'echo "{\\"event\\":\\"error\\",\\"code\\":\\"cancelled\\",\\"message\\":\\"Cancelled.\\"}"; exit 130' TERM
          echo '{"event":"progress","progress":0.1,"label":"Restoring the voice","eta":30}'
          sleep 30 & wait
          exit 0 ;;
        stubborn*)
          trap '' TERM
          echo '{"event":"progress","progress":0.1,"label":"Restoring the voice","eta":30}'
          sleep 30
          exit 0 ;;
        esac
        printf '{"event":"start","name":"%s","duration":8.0,"has_video":false,"meta":"0:08 · WAV","eta":2.0}\\n' "$name"
        printf '{"event":"progress","progr'
        sleep 0.05
        printf 'ess":0.5,"stage":"restore","label":"Restoring the voice","eta":1.0,"new_key":1}\\n{"event":"mystery"}\\n'
        echo 'not an event'
        printf '{"event":"done","output":"%s","wav":"%s","stems":"%s","took":1.5,"music":true,"mix":{"speech":54,"background":10,"music":10}}' "$7" "$7" "$5"
        exit 0
        """
    }
}

/// Collects one job's events.
@MainActor
final class EventRecorder {
    var events: [EngineEvent] = []
    var terminal: [EngineEvent] {
        events.filter {
            if case .done = $0 { return true }
            if case .error = $0 { return true }
            return false
        }
    }

    func record(_ event: EngineEvent) { events.append(event) }
}

@MainActor
func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Engine runner", .serialized)
@MainActor
struct EngineRunnerTests {
    func run(_ name: String, engine: ScriptEngine, runner: EngineJobRunner? = nil, cancelAfter: Duration? = nil) async throws -> EventRecorder {
        let locator = engine.locator()
        guard case .ready = await locator.locate() else {
            Issue.record("script engine not ready")
            return EventRecorder()
        }
        let runner = runner ?? EngineJobRunner(locator: locator)
        let job = Job(input: engine.input(name))
        let options = RunOptions(
            output: engine.input("out-\(name)"), stemsDirectory: engine.stemsRoot.appendingPathComponent(job.id.uuidString))
        let recorder = EventRecorder()
        runner.start(job: job, options: options) { recorder.record($0) }
        if let cancelAfter {
            try await Task.sleep(for: cancelAfter)
            runner.cancel(jobID: job.id)
        }
        await waitFor { !recorder.terminal.isEmpty && runner.runningJobIDs.isEmpty }
        // Nothing may arrive after the terminal event.
        try await Task.sleep(for: .milliseconds(50))
        return recorder
    }

    @Test func deliversEventsInOrderWithSplitLines() async throws {
        let engine = try ScriptEngine()
        let recorder = try await run("take.wav", engine: engine)
        let kinds = recorder.events.map { event -> String in
            switch event {
            case .hello: "hello"
            case .start: "start"
            case .progress: "progress"
            case .done: "done"
            case .unknown(let name): "unknown:\(name)"
            default: "other"
            }
        }
        #expect(kinds == ["hello", "start", "progress", "unknown:mystery", "done"])
        guard case .done(let done) = recorder.events.last else { return }
        #expect(done.music && done.took == 1.5)
        #expect(done.output == engine.input("out-take.wav").path)
        if case .progress(let progress) = recorder.events[2] {
            #expect(progress.progress == 0.5 && progress.label == "Restoring the voice")
        }
    }

    @Test func createsTheStemsDirectoryAndRunsInIt() async throws {
        let engine = try ScriptEngine()
        let recorder = try await run("take.wav", engine: engine)
        guard case .done(let done) = recorder.terminal.first, let stems = done.stems else {
            Issue.record("no done event")
            return
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: stems, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(URL(fileURLWithPath: stems).deletingLastPathComponent().path == engine.stemsRoot.path)
    }

    @Test func crashWithoutAnErrorEventBecomesEngineFailed() async throws {
        let engine = try ScriptEngine()
        let recorder = try await run("crash.wav", engine: engine)
        #expect(recorder.terminal.count == 1)
        guard case .error(let error) = recorder.terminal.first else { return }
        #expect(error.code == .engineFailed)
        #expect(Formatting.errorBody(for: error) == "The engine stopped unexpectedly: RuntimeError: boom")
    }

    @Test func cleanExitWithoutResultIsAFailureToo() async throws {
        let engine = try ScriptEngine()
        let recorder = try await run("silent.wav", engine: engine)
        #expect(recorder.terminal == [.error(JobError(code: .engineFailed, message: EngineFailure.silentExit))])
    }

    @Test func engineErrorsPassThrough() async throws {
        let engine = try ScriptEngine()
        let recorder = try await run("refuse.mov", engine: engine)
        #expect(recorder.terminal == [.error(.noAudio(fileName: "refuse.mov"))])
    }

    @Test func cancelEndsWithOneCancelledError() async throws {
        let engine = try ScriptEngine()
        let started = Date()
        let recorder = try await run("slow.wav", engine: engine, cancelAfter: .milliseconds(400))
        #expect(recorder.terminal == [.error(JobError(code: .cancelled, message: "Cancelled."))])
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancelEscalatesToSigkill() async throws {
        let engine = try ScriptEngine()
        let locator = engine.locator()
        _ = await locator.locate()
        let runner = EngineJobRunner(locator: locator, cancelGracePeriod: 0.5)
        let recorder = try await run("stubborn.wav", engine: engine, runner: runner, cancelAfter: .milliseconds(300))
        #expect(recorder.terminal == [.error(JobError(code: .cancelled, message: "Cancelled."))])
    }

    @Test func cancelAllEndsEveryJob() async throws {
        let engine = try ScriptEngine()
        let locator = engine.locator()
        _ = await locator.locate()
        let runner = EngineJobRunner(locator: locator)
        let recorder = EventRecorder()
        let job = Job(input: engine.input("slow.wav"))
        runner.start(job: job, options: RunOptions(output: engine.input("o.wav"), stemsDirectory: engine.stemsRoot.appendingPathComponent("a"))) {
            recorder.record($0)
        }
        await waitFor { !recorder.events.isEmpty }
        runner.cancelAll()
        #expect(recorder.terminal == [.error(JobError(code: .cancelled, message: "Cancelled."))])
        await waitFor { runner.runningJobIDs.isEmpty }
        #expect(runner.runningJobIDs.isEmpty)
    }

    @Test func aCancelledJobsStemsGoOnceTheEngineHasExited() async throws {
        let engine = try ScriptEngine()
        let locator = engine.locator()
        _ = await locator.locate()
        let runner = EngineJobRunner(locator: locator)
        let recorder = EventRecorder()
        let stems = engine.stemsRoot.appendingPathComponent("cancelled", isDirectory: true)
        runner.start(job: Job(input: engine.input("slow.wav")), options: RunOptions(output: engine.input("o.wav"), stemsDirectory: stems)) {
            recorder.record($0)
        }
        await waitFor { !recorder.events.isEmpty }
        #expect(FileManager.default.fileExists(atPath: stems.path)) // the engine is still in it
        runner.cancel(jobID: runner.runningJobIDs[0])
        await waitFor { runner.runningJobIDs.isEmpty }
        await waitFor(3) { !FileManager.default.fileExists(atPath: stems.path) }
        #expect(!FileManager.default.fileExists(atPath: stems.path))
    }

    @Test func aCrashedJobsStemsGoToo() async throws {
        let engine = try ScriptEngine()
        let recorder = try await run("crash.wav", engine: engine)
        #expect(!recorder.terminal.isEmpty)
        await waitFor(3) { ((try? FileManager.default.contentsOfDirectory(atPath: engine.stemsRoot.path)) ?? []).isEmpty }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: engine.stemsRoot.path)) ?? []).isEmpty)
    }

    /// Eleven files in one session: the first job's stems must still be there for its Done
    /// screen, while old folders nobody lists are pruned down to ten.
    @Test func sessionJobsKeepTheirStems() async throws {
        let engine = try ScriptEngine()
        let root = engine.stemsRoot
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var stale: [URL] = []
        for i in 0..<12 {
            let folder = root.appendingPathComponent("stale-\(i)", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-1000 + i))], ofItemAtPath: folder.path)
            stale.append(folder)
        }

        let locator = engine.locator()
        let runner = EngineJobRunner(locator: locator)
        let model = AppModel(
            settings: Settings(store: InMemorySettingsStore()),
            dependencies: AppDependencies(
                engine: EngineServices(
                    locator: locator, jobs: runner, setup: ManualSetupRunner(), remixer: FakeRemixer(delay: .zero),
                    player: RecordingPreviewPlayer()),
                system: .recording),
            stemsRoot: root)
        await model.checkEngine()
        #expect(model.setup == .ready)
        for i in 1...11 { // one file after another, each done before the next arrives
            model.enqueue([engine.input("take\(i).wav")])
            await waitFor(10) { model.jobs.count == i && model.activeID == nil }
        }
        #expect(model.jobs.allSatisfy { $0.state == .done })
        try await Task.sleep(for: .milliseconds(300)) // the last prune runs in the background

        for job in model.jobs {
            #expect(manager.fileExists(atPath: root.appendingPathComponent(job.id.uuidString).path), "\(job.name)")
        }
        #expect(!manager.fileExists(atPath: stale[0].path))
        #expect(!manager.fileExists(atPath: stale[1].path))
        #expect(stale.dropFirst(2).allSatisfy { manager.fileExists(atPath: $0.path) })
    }

    @Test func withoutAnEngineTheJobAsksForSetup() async throws {
        let engine = try ScriptEngine()
        let runner = EngineJobRunner(locator: engine.locator()) // never located
        let recorder = EventRecorder()
        runner.start(job: Job(input: engine.input("a.wav")), options: RunOptions(output: engine.input("o.wav"), stemsDirectory: engine.stemsRoot)) {
            recorder.record($0)
        }
        #expect(recorder.events.isEmpty) // reported on a later turn, never re-entrantly
        await waitFor { !recorder.events.isEmpty }
        guard case .error(let error) = recorder.terminal.first else {
            Issue.record("expected an error")
            return
        }
        #expect(error.code == .setupRequired)
    }
}

@Suite("Engine locator", .serialized)
@MainActor
struct EngineLocatorTests {
    @Test func acceptsProtocolOneAndCachesTheAnswer() async throws {
        let engine = try ScriptEngine()
        let locator = engine.locator()
        guard case .ready(let installation) = await locator.locate() else {
            Issue.record("expected ready")
            return
        }
        #expect(installation.executable.path == engine.executable.path)
        #expect(installation.info.version == "9.9")
        _ = await locator.locate()
        let calls = try String(contentsOf: engine.directory.appendingPathComponent("calls.log"), encoding: .utf8)
        #expect(calls.split(separator: "\n") == ["app-info"])
    }

    @Test func rejectsAnotherProtocol() async throws {
        let engine = try ScriptEngine(protocolVersion: 2)
        #expect(await engine.locator().locate() == .needsSetup(nil))
    }

    @Test func notReadyNeedsSetupWithTheInstallation() async throws {
        let engine = try ScriptEngine(ready: false)
        let locator = engine.locator()
        guard case .needsSetup(let installation?) = await locator.locate() else {
            Issue.record("expected needsSetup with an installation")
            return
        }
        #expect(installation.info.missing == ["sidon-weights"])
        #expect(locator.installation == installation)
    }

    @Test func aSlowAppInfoIsWaitedForNotRejected() async throws {
        let engine = try ScriptEngine(appInfoDelay: 3)
        let locator = engine.locator(validationTimeout: 0.5, responseTimeout: 10)
        var waitingOn: [EngineCandidate] = []
        let availability = await locator.locate { waitingOn.append($0) }
        guard case .ready(let installation) = availability else {
            Issue.record("expected ready, got \(availability)")
            return
        }
        #expect(installation.executable.path == engine.executable.path)
        #expect(waitingOn == [EngineCandidate(path: engine.executable.path, source: .launchArgument)])
        #expect(!locator.lastSearchTimedOut)
        #expect(engine.calls == ["app-info"]) // the same process, waited on, never relaunched
    }

    @Test func aSlowEngineThatNeedsModelsIsSetUpNotReinstalled() async throws {
        let engine = try ScriptEngine(ready: false, appInfoDelay: 1.5)
        let locator = engine.locator(validationTimeout: 0.3, responseTimeout: 10)
        var waits = 0
        guard case .needsSetup(let installation?) = await locator.locate(onWaiting: { _ in waits += 1 }) else {
            Issue.record("expected needsSetup with the slow engine")
            return
        }
        #expect(installation.executable.path == engine.executable.path)
        #expect(waits == 1)

        let runner = SetupRunner(locator: locator, installer: ManagedEngineInstaller(toolchain: engine.toolchain, source: nil))
        let recorder = EventRecorder()
        runner.start { recorder.record($0) }
        await waitFor(15) { !recorder.terminal.isEmpty }
        #expect(recorder.terminal == [.done(EngineDone())])
        #expect(!recorder.events.contains { event in
            if case .setup(let progress) = event { return progress.phase == SetupProgressCombiner.installPhase }
            return false
        })
        #expect(engine.calls == ["app-info", "setup", "app-info"])
        #expect(!FileManager.default.fileExists(atPath: EngineSearch.managedEngineDirectory(home: engine.directory).path))
    }

    @Test func anEngineThatNeverAnswersIsUnresponsiveAndNothingIsInstalled() async throws {
        let engine = try ScriptEngine(appInfoDelay: 30)
        let locator = engine.locator(validationTimeout: 0.3, responseTimeout: 1)
        let started = Date()
        var waits = 0
        let availability = await locator.locate { _ in waits += 1 }
        #expect(availability == .unresponsive(EngineCandidate(path: engine.executable.path, source: .launchArgument)))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(waits == 1)
        #expect(locator.lastSearchTimedOut)
        #expect(locator.installation == nil)

        // Setup (what Try again used to run) refuses to install over it.
        let runner = SetupRunner(locator: locator, installer: ManagedEngineInstaller(toolchain: engine.toolchain, source: nil))
        let recorder = EventRecorder()
        runner.start { recorder.record($0) }
        await waitFor(5) { !recorder.terminal.isEmpty }
        let folder = Formatting.engineFolder(executablePath: engine.executable.path, home: engine.directory.path)
        #expect(recorder.terminal == [.error(JobError(code: .setupFailed, message: Formatting.engineUnresponsiveMessage(folder: folder)))])
        #expect(!recorder.events.contains { event in
            if case .setup(let progress) = event { return progress.phase == SetupProgressCombiner.installPhase }
            return false
        })
        #expect(!FileManager.default.fileExists(atPath: EngineSearch.managedEngineDirectory(home: engine.directory).path))
    }

    @Test func anEngineThatExitsWithoutAnsweringStillNeedsSetup() async throws {
        let engine = try ScriptEngine(appInfoAnswers: false)
        let locator = engine.locator(validationTimeout: 0.3, responseTimeout: 2)
        #expect(await locator.locate() == .needsSetup(nil))
        #expect(!locator.lastSearchTimedOut)
    }

    @Test func aTimedOutCandidateStopsTheSearch() async throws {
        let engine = try ScriptEngine(appInfoDelay: 30)
        // A perfectly good engine further down the list, in this home's ~/.local/bin.
        let fallback = engine.directory.appendingPathComponent(".local/bin/booth")
        try ScriptEngine.install(ScriptEngine.script(), at: fallback)
        let locator = engine.locator(validationTimeout: 0.3, responseTimeout: 1)
        let availability = await locator.locate()
        #expect(availability == .unresponsive(EngineCandidate(path: engine.executable.path, source: .launchArgument)))
        #expect(!FileManager.default.fileExists(atPath: fallback.deletingLastPathComponent().appendingPathComponent("calls.log").path))

        // Without the silent one, the fallback is found as before.
        let healthy = EngineLocator(
            toolchain: engine.toolchain, launchArgument: nil, storedPreference: { nil }, environment: [:],
            infoPlistPath: nil, validationTimeout: 0.3, responseTimeout: 1)
        guard case .ready(let installation) = await healthy.locate() else {
            Issue.record("expected the ~/.local/bin engine")
            return
        }
        #expect(installation.executable.path == fallback.path)
    }

    @Test func aModelWaitsForASlowEngineAndThenUsesIt() async throws {
        let engine = try ScriptEngine(appInfoDelay: 1.5)
        let locator = engine.locator(validationTimeout: 0.3, responseTimeout: 10)
        let setup = ManualSetupRunner()
        let model = AppModel(
            settings: Settings(store: InMemorySettingsStore()),
            dependencies: AppDependencies(
                engine: EngineServices(
                    locator: locator, jobs: ManualJobRunner(), setup: setup, remixer: FakeRemixer(delay: .zero),
                    player: RecordingPreviewPlayer()),
                system: .recording),
            stemsRoot: engine.stemsRoot)
        let checking = Task { await model.checkEngine() }
        await waitFor(5) { model.setup.isWaitingForEngine }
        let folder = Formatting.engineFolder(executablePath: engine.executable.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(model.setup == .waitingForEngine(folder: folder))
        #expect(model.setupWaitingText == Formatting.engineWaitingBody(folder: folder))
        #expect(model.glyphMode == .working)
        model.open()
        #expect(model.effectiveScreen == .firstrun)
        model.enqueue([engine.input("early.wav")]) // queues meanwhile
        #expect(model.queuedJobs.count == 1)
        await checking.value
        #expect(model.setup == .ready)
        #expect(model.setupWaitingText == nil)
        #expect(setup.startCount == 0)
        #expect(model.activeJob?.name == "early.wav")
    }

    @Test func remixReturnsTheEnginesDone() async throws {
        let engine = try ScriptEngine()
        let locator = engine.locator()
        _ = await locator.locate()
        let stems = engine.directory.appendingPathComponent("stems", isDirectory: true)
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stems.appendingPathComponent("manifest.json"))
        let done = try await EngineRemixer(locator: locator).remix(
            JobResult(output: URL(fileURLWithPath: "/tmp/out.wav"), stems: stems), to: Mix(speech: 70, background: 20, music: 5))
        #expect(done.mix == Mix(speech: 70, background: 20, music: 5))
    }

    @Test func remixWithoutStemsFailsClearly() async throws {
        let engine = try ScriptEngine()
        let locator = engine.locator()
        _ = await locator.locate()
        await #expect(throws: JobError.self) {
            _ = try await EngineRemixer(locator: locator).remix(JobResult(output: URL(fileURLWithPath: "/tmp/out.wav")), to: .standard)
        }
    }
}

@Suite("Engine toolchain", .serialized)
@MainActor
struct EngineToolchainTests {
    /// A bundled uv (an assembled app) would be found first and hide the retry.
    nonisolated static let noBundledUV = AppResources.url("bin/uv") == nil

    @Test(.enabled(if: noBundledUV))
    func aMissingUvIsLookedForAgain() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("booth-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let toolchain = EngineToolchain(
            home: home, baseEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": "/usr/bin/false"],
            toolDirectories: [localBin.path])
        await toolchain.prepare()
        #expect(toolchain.uv == nil)

        // "Install uv, then try again."
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let uv = localBin.appendingPathComponent("uv")
        try "#!/bin/sh\nexit 0\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        await toolchain.prepare()
        #expect(toolchain.uv?.path == uv.path)
        #expect(toolchain.environment[EngineEnvironment.uvKey] == uv.path)

        // Found once, kept: removing it does not trigger another search.
        try FileManager.default.removeItem(at: uv)
        await toolchain.prepare()
        #expect(toolchain.uv?.path == uv.path)
    }

    @Test(.enabled(if: noBundledUV))
    func concurrentPreparesShareOneSearch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("booth-home-\(UUID().uuidString)", isDirectory: true)
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let uv = localBin.appendingPathComponent("uv")
        try "#!/bin/sh\nexit 0\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let toolchain = EngineToolchain(
            home: home, baseEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": "/usr/bin/false"],
            toolDirectories: [localBin.path])
        async let first: Void = toolchain.prepare()
        async let second: Void = toolchain.prepare()
        _ = await (first, second)
        #expect(toolchain.uv?.path == uv.path)
    }
}

/// Opt-in, slow and networked: creates a real managed install from this repository with
/// `uv sync`, in a scratch home so the user's Application Support is untouched. Run with
/// `BOOTH_TEST_MANAGED_INSTALL=1 [BOOTH_TEST_HOME=/some/dir] [BOOTH_TEST_ENGINE_SOURCE=<repo>]
/// swift test --filter managedInstall`.
@Suite("Managed install", .serialized)
@MainActor
struct ManagedInstallTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["BOOTH_TEST_MANAGED_INSTALL"] == "1"), .timeLimit(.minutes(30)))
    func managedInstallFromTheRepository() async throws {
        let home = URL(fileURLWithPath: Self.environment["BOOTH_TEST_HOME"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("booth-home-\(UUID().uuidString)").path)
        var base = Self.environment
        base["SHELL"] = "/usr/bin/false" // keep the user's own booth out of the search
        let toolchain = EngineToolchain(home: home, baseEnvironment: base)
        let locator = EngineLocator(toolchain: toolchain, launchArgument: nil, storedPreference: { nil }, environment: [:], infoPlistPath: nil)
        #expect(await locator.locate() == .needsSetup(nil))

        let source = Self.environment["BOOTH_TEST_ENGINE_SOURCE"].map { URL(fileURLWithPath: $0) } ?? ManagedEngineInstaller.bundledSource()
        let runner = SetupRunner(locator: locator, installer: ManagedEngineInstaller(toolchain: toolchain, source: source))
        let recorder = EventRecorder()
        runner.start { recorder.record($0) }
        await waitFor(29 * 60) { !recorder.terminal.isEmpty }

        let progress = recorder.events.compactMap { event -> SetupProgress? in
            if case .setup(let progress) = event { return progress }
            return nil
        }
        print("managed install: \(progress.count) progress events, last \(progress.last.map { "\($0.bytesDone)/\($0.bytesTotal)" } ?? "none")")
        #expect(recorder.terminal == [.done(EngineDone())])
        #expect(!progress.isEmpty)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone })
        #expect(locator.installation?.executable.path == EngineSearch.managedExecutable(home: home).path)
        #expect(await locator.locate() == .ready(try #require(locator.installation)))
    }
}
