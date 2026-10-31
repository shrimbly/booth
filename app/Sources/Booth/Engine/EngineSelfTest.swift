import AVFoundation
import BoothCore
import Foundation

/// `--selftest-engine PATH [--selftest-engine-name NAME] [--engine EXE]
/// [--selftest-cancel-after SECONDS] [--selftest-remix]`: runs one real job headlessly through
/// the live locator and runner, printing every event as a line.
///
/// Exits 0 when the job is done (after checking the output, the stems and an offline preview
/// render, and the remix when asked), 1 otherwise. SIGINT/SIGTERM cancel the job the way the
/// app does, so the engine is never orphaned.
///
/// Runs on the main thread before NSApplication starts. Runner callbacks arrive on the main
/// queue, so it spins the main run loop while it waits.
@MainActor
enum EngineSelfTest {
    static func run(input: URL, engineName: String, enginePath: String?) -> Int32 {
        let extras = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let session = SelfTestSession(
            input: input,
            engine: EngineChoice(engineName: engineName) ?? .studio,
            enginePath: enginePath,
            cancelAfter: extras.selfTestCancelAfter,
            remix: extras.selfTestRemix)
        return session.run()
    }
}

@MainActor
private final class SelfTestSession {
    let input: URL
    let engine: EngineChoice
    let enginePath: String?
    let cancelAfter: Double?
    let remix: Bool

    private var terminal: EngineEvent?
    private var cancelledAt: Date?
    private var signalSources: [DispatchSourceSignal] = []
    private let started = Date()

    init(input: URL, engine: EngineChoice, enginePath: String?, cancelAfter: Double?, remix: Bool) {
        self.input = input
        self.engine = engine
        self.enginePath = enginePath
        self.cancelAfter = cancelAfter
        self.remix = remix
    }

    func run() -> Int32 {
        say("selftest: \(input.path) with \(engine.engineName)")
        guard FileManager.default.fileExists(atPath: input.path) else {
            say("FAIL: \(input.path) does not exist")
            return 1
        }

        let toolchain = EngineToolchain()
        let locator = EngineLocator(
            toolchain: toolchain, launchArgument: enginePath, storedPreference: { Settings().enginePath })
        guard let availability = wait(for: { await locator.locate() }, timeout: 200) else { // past app-info's 180 s
            say("FAIL: locating the engine timed out")
            return 1
        }
        switch availability {
        case .ready(let installation):
            say("engine: \(installation.executable.path) version \(installation.info.version), ready")
        case .needsSetup(let installation?):
            say("FAIL: engine \(installation.executable.path) is not ready; missing \(installation.info.missing.joined(separator: ", "))")
            return 1
        case .needsSetup(nil) where locator.managedInstallNeedsUpdate:
            say("FAIL: the managed engine is older than the one bundled with Booth; open Booth to update it")
            return 1
        case .needsSetup(nil):
            say("FAIL: no engine found (see \(Log.fileURL.path))")
            return 1
        case .unresponsive(let candidate):
            say("FAIL: engine \(candidate.path) [\(candidate.source.rawValue)] did not answer app-info")
            return 1
        }

        let job = Job(input: input)
        let output = OutputNaming.outputURL(for: input, keepVideo: true)
        let stems = AppModel.defaultStemsRoot.appendingPathComponent(job.id.uuidString, isDirectory: true)
        let options = RunOptions(output: output, stemsDirectory: stems, engine: engine)
        let runner = EngineJobRunner(locator: locator)
        cancelOnSignals { [weak self] in self?.cancel(job.id, on: runner, reason: "signal") }
        if let cancelAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + cancelAfter) { [weak self] in
                MainActor.assumeIsolated { self?.cancel(job.id, on: runner, reason: "--selftest-cancel-after \(cancelAfter)") }
            }
        }

        runner.start(job: job, options: options) { [weak self] event in self?.receive(event) }
        // Wait for the terminal event and for the process itself to be gone.
        let finished = spin(timeout: 6 * 60 * 60) { [unowned self] in terminal != nil && runner.runningJobIDs.isEmpty }
        guard finished, let terminal else {
            say("FAIL: no result before the timeout")
            runner.cancelAll()
            return 1
        }

        switch terminal {
        case .done(let done):
            return verify(done, locator: locator) ? 0 : 1
        case .error(let error):
            // The runner deletes a failed job's folder in the background, which this process
            // may not live to see; delete it here so no empty folder stays in the cache.
            try? FileManager.default.removeItem(at: stems)
            if error.code == .cancelled, let cancelledAt {
                let leftovers = OutputNaming.fileExists(output) ? "output exists (unexpected)" : "no output written"
                say(String(format: "cancelled %.2f s after the request; %@", Date().timeIntervalSince(cancelledAt), leftovers))
            }
            return 1
        default:
            return 1
        }
    }

    // MARK: - Checks

    private func verify(_ done: EngineDone, locator: EngineLocator) -> Bool {
        guard var result = JobResult(done: done) else {
            say("FAIL: done without an output")
            return false
        }
        var ok = check(OutputNaming.fileExists(result.output), "output \(result.output.path)")
        if let video = result.video { ok = check(OutputNaming.fileExists(video), "video \(video.path)") && ok }
        if let wav = result.wav { ok = check(OutputNaming.fileExists(wav), "wav \(wav.path)") && ok }

        guard let stems = result.stems else {
            say("no stems directory reported")
            return ok
        }
        do {
            let manifest = try StemsManifest.load(from: stems)
            result.manifest = manifest
            say("manifest: \(manifest.name), \(manifest.duration) s, music \(manifest.music), mix \(describe(manifest.mix)), \(manifest.bars.clean.count) bars")
        } catch {
            ok = check(false, "manifest in \(stems.path): \(error)")
        }
        for stem in PreviewStem.allCases {
            let url = stem.url(in: stems)
            let present = OutputNaming.fileExists(url)
            if stem == .music && !result.music {
                say("\(stem.fileName): \(present ? "present" : "absent (no music)")")
            } else {
                ok = check(present, stem.fileName) && ok
            }
        }
        ok = checkPreview(result) && ok
        if remix { ok = checkRemix(result, locator: locator) && ok }
        say(ok ? "PASS: \(result.output.path)" : "FAIL: see above")
        return ok
    }

    /// Renders up to three seconds of the preview offline (no sound plays), then as much of the
    /// original while comparing, and checks neither is silent.
    private func checkPreview(_ result: JobResult) -> Bool {
        let duration = result.manifest?.duration ?? 1
        let window = AVAudioFrameCount(min(3, duration / 2.2) * Double(result.manifest?.sampleRate ?? 48_000))
        let player = PreviewPlayer(output: .offline)
        player.load(result)
        player.setGains(result.mix.gains(curve: result.curve, includeMusic: result.music))
        player.play()
        do {
            let enhanced = try player.renderOffline(frames: window)
            player.setComparing(true)
            _ = try player.renderOffline(frames: 2_400) // let the 30 ms glide finish
            let original = try player.renderOffline(frames: window)
            player.pause()
            let enhancedLevel = rms(enhanced), originalLevel = rms(original)
            say(String(format: "preview: enhanced RMS %.4f, original RMS %.4f", enhancedLevel, originalLevel))
            return check(enhancedLevel > 0.0005 && originalLevel > 0.0005, "preview renders sound")
        } catch {
            return check(false, "preview render: \(error)")
        }
    }

    private func checkRemix(_ result: JobResult, locator: EngineLocator) -> Bool {
        let target = Mix(speech: 72, background: 28, music: 10)
        let before = modificationDate(result.output)
        let remixer = EngineRemixer(locator: locator)
        let began = Date()
        let outcome: Result<EngineDone, Error>? = wait(for: {
            do { return .success(try await remixer.remix(result, to: target)) } catch { return .failure(error) }
        }, timeout: 10 * 60)
        switch outcome {
        case .success(let done)?:
            say(String(format: "remix: done in %.1f s (engine took %.1f s), mix %@", Date().timeIntervalSince(began), done.took ?? 0, describe(done.mix ?? target)))
            var ok = check(done.mix == target, "remix reports the new mix")
            if let after = modificationDate(result.output), let before { ok = check(after > before, "remix rewrote the output") && ok }
            if let stems = result.stems, let manifest = try? StemsManifest.load(from: stems) {
                ok = check(manifest.mix == target, "manifest mix updated to \(describe(manifest.mix))") && ok
            }
            return ok
        case .failure(let error)?:
            return check(false, "remix: \((error as? JobError)?.message ?? "\(error)")")
        case nil:
            return check(false, "remix timed out")
        }
    }

    // MARK: - Events

    private func receive(_ event: EngineEvent) {
        say(describe(event))
        switch event {
        case .done, .error: terminal = event
        default: break
        }
    }

    private func cancel(_ id: Job.ID, on runner: EngineJobRunner, reason: String) {
        guard terminal == nil, cancelledAt == nil else { return }
        cancelledAt = Date()
        say(String(format: "cancel (%@) at %.2f s", reason, Date().timeIntervalSince(started)))
        runner.cancel(jobID: id)
    }

    private func cancelOnSignals(_ handler: @escaping @MainActor () -> Void) {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { handler() } }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Helpers

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    private func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }

    /// Runs async main-actor work while spinning the run loop for it.
    private func wait<T>(for work: @escaping @MainActor () async -> T, timeout: TimeInterval) -> T? {
        let box = ResultBox<T>()
        Task { @MainActor in box.value = await work() }
        _ = spin(timeout: timeout) { box.value != nil }
        return box.value
    }

    private func check(_ condition: Bool, _ what: String) -> Bool {
        say("\(condition ? "ok" : "FAIL"): \(what)")
        return condition
    }

    private func say(_ line: String) {
        print(line)
        fflush(stdout)
        Log.info("selftest: \(line)")
    }

    private func describe(_ event: EngineEvent) -> String {
        switch event {
        case .hello(let hello):
            return "hello protocol=\(hello.protocolVersion) version=\(hello.version)"
        case .start(let start):
            return "start name=\(start.name ?? "?") duration=\(start.duration.map { String($0) } ?? "?") meta=\"\(start.meta ?? "")\" engine=\(start.engine ?? "?") eta=\(start.eta.map { String(format: "%.1f", $0) } ?? "?")"
        case .progress(let progress):
            return String(format: "progress %3d%% %@ \"%@\" eta=%@", Formatting.percent(progress.progress), progress.stage ?? "-", progress.label ?? "", progress.eta.map { String(format: "%.1f", $0) } ?? "?")
        case .done(let done):
            return "done output=\(done.output ?? "nil") took=\(done.took.map { String($0) } ?? "?") music=\(done.music) stems=\(done.stems ?? "nil")"
        case .error(let error):
            return "error code=\(error.code) message=\(error.message.split(whereSeparator: \.isNewline).first ?? "")"
        case .info, .setup, .setupStatus, .unknown:
            return "event \(event)"
        }
    }

    private func describe(_ mix: Mix) -> String {
        "s\(mix.speech) b\(mix.background) m\(mix.music)"
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

@MainActor
private final class ResultBox<T> {
    var value: T?
}
