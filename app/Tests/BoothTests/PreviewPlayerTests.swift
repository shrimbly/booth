import AppKit
import AVFoundation
import BoothCore
import Foundation
import Testing
@testable import Booth

/// Synthetic preview stems on disk: each stem is a constant so the mix is easy to predict.
@MainActor
struct StemFixture {
    static let sampleRate = 48_000
    let directory: URL

    /// `seconds` long; `music` adds a music stem.
    init(seconds: Double = 1, music: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("booth-stems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = Int(seconds * Double(Self.sampleRate))
        try Self.write(0.5, frames: frames, to: PreviewStem.clean.url(in: directory))
        try Self.write(0.1, frames: frames, to: PreviewStem.vocals.url(in: directory))
        try Self.write(0.2, frames: frames, to: PreviewStem.background.url(in: directory))
        try Self.write(0.3, frames: frames, to: PreviewStem.original.url(in: directory))
        if music { try Self.write(0.4, frames: frames, to: PreviewStem.music.url(in: directory)) }
    }

    var result: JobResult {
        JobResult(output: directory.appendingPathComponent("out.wav"), stems: directory)
    }

    /// The result with a manifest saying how the job was rendered (auto loudness unless told).
    func result(settings: StemsManifest.RenderSettings) -> JobResult {
        let zeros = [Double](repeating: 0, count: 4)
        let manifest = StemsManifest(
            input: "/in.wav", name: "in.wav", duration: 1, hasVideo: false, engine: "sidon", generative: true,
            music: false, outputs: .init(wav: "/out.wav"), settings: settings,
            bars: .init(clean: zeros, vocals: zeros, background: zeros, original: zeros))
        return JobResult(output: directory.appendingPathComponent("out.wav"), stems: directory, manifest: manifest)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A float32 mono WAV holding `value` in every sample.
    static func write(_ value: Float, frames: Int, to url: URL) throws {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var samples = Data(capacity: frames * 4)
        let bits = le(value.bitPattern)
        for _ in 0..<frames { samples += bits }
        var fmt = Data()
        fmt += le(UInt16(3)) + le(UInt16(1)) + le(UInt32(sampleRate)) + le(UInt32(sampleRate * 4)) + le(UInt16(4)) + le(UInt16(32))
        var body = Data("WAVE".utf8) + Data("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
        body += Data("data".utf8) + le(UInt32(samples.count)) + samples
        try (Data("RIFF".utf8) + le(UInt32(body.count)) + body).write(to: url)
    }
}

@Suite("Preview player", .serialized)
@MainActor
struct PreviewPlayerTests {
    let speechOnly = StemGains(clean: 1, vocals: 0, background: 0, music: 0)

    func near(_ samples: ArraySlice<Float>, _ expected: Float, tolerance: Float = 0.0005) -> Bool {
        !samples.isEmpty && samples.allSatisfy { abs($0 - expected) <= tolerance }
    }

    @Test func mixesStemsWithTheGains() throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result)
        player.setGains(StemGains(clean: 0.75, vocals: 0.25, background: 0.5, music: 0))
        player.play()
        let samples = try player.renderOffline(frames: 4_800)
        // 0.75·0.5 + 0.25·0.1 + 0.5·0.2 = 0.5, after the 5 ms (240-sample) fade-in.
        #expect(near(samples[300...], 0.5))
        #expect(samples[0] < 0.01)
    }

    @Test func comparingGlidesToTheOriginal() throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result)
        player.setGains(speechOnly)
        player.play()
        _ = try player.renderOffline(frames: 2_400)
        player.setComparing(true)
        let gliding = try player.renderOffline(frames: 4_800)
        // A 30 ms glide (1440 samples): no jump at the start, the original alone after it.
        #expect(abs(gliding[0] - 0.5) < 0.01)
        #expect(near(gliding[1_500...], 0.3))
        let steps = zip(gliding.dropFirst(), gliding).map { abs($0 - $1) }
        #expect(steps.max() ?? 1 < 0.001)
        player.setComparing(false)
        let back = try player.renderOffline(frames: 4_800)
        #expect(near(back[1_500...], 0.5))
    }

    @Test func liveGainChangesTakeEffectWhilePlaying() throws {
        let stems = try StemFixture(music: true)
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result)
        player.setGains(speechOnly)
        player.play()
        _ = try player.renderOffline(frames: 2_400)
        player.setGains(StemGains(clean: 1, vocals: 0, background: 0, music: 0.5))
        let samples = try player.renderOffline(frames: 4_800)
        #expect(near(samples[2_000...], 0.5 + 0.5 * 0.4))
    }

    @Test func publishesThePlayheadAndRewindsAtTheEnd() throws {
        let stems = try StemFixture(seconds: 0.25)
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(stems.result)
        player.setGains(speechOnly)
        player.play()
        #expect(statuses.last == PlaybackStatus(isPlaying: true, playhead: 0))
        _ = try player.renderOffline(frames: 6_000) // half of 12 000 frames
        player.tick()
        #expect(statuses.last == PlaybackStatus(isPlaying: true, playhead: 0.5))
        _ = try player.renderOffline(frames: 8_000) // past the end
        player.tick()
        #expect(statuses.last == PlaybackStatus(isPlaying: false, playhead: 0))
        // Playing again starts from the top.
        player.play()
        let again = try player.renderOffline(frames: 2_400)
        #expect(near(again[300...], 0.5))
    }

    @Test func seekJumpsWithoutAClick() throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(stems.result)
        player.setGains(speechOnly)
        player.play()
        _ = try player.renderOffline(frames: 2_400)
        player.seek(to: 0.75)
        #expect(statuses.last?.playhead == 0.75)
        _ = try player.renderOffline(frames: 2_400)
        player.tick()
        // 36 000 + whatever played after the fade: within 2 400 frames of 0.75.
        let head = try #require(statuses.last?.playhead)
        #expect(head > 0.75 && head < 0.81)
    }

    @Test func playheadIsWhatIsHeard() throws {
        let stems = try StemFixture() // 48 000 frames
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.outputLatency = 0.05 // 2 400 frames between rendering a sample and hearing it
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(stems.result)
        player.play()
        _ = try player.renderOffline(frames: 4_800)
        player.tick()
        #expect(statuses.last?.playhead == 0.05)

        // After a jump the old sound is still on its way out: the playhead waits at the target
        // instead of running back before it.
        player.seek(to: 0.5)
        _ = try player.renderOffline(frames: 960)
        player.tick()
        #expect(statuses.last?.playhead == 0.5)
        _ = try player.renderOffline(frames: 4_800)
        player.tick()
        // About 5 520 frames past the target (after the 240-frame fade-out), less the latency.
        let head = try #require(statuses.last?.playhead)
        #expect(head > 0.56 && head < 0.57)
    }

    /// Play after a pause: until the new sound arrives, nothing new is published, so the video
    /// (which follows the playhead) doesn't start ahead of the voice.
    @Test func playheadHoldsUntilTheNewSoundIsHeard() throws {
        let stems = try StemFixture() // 48 000 frames
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.outputLatency = 0.05
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(stems.result)
        player.play()
        _ = try player.renderOffline(frames: 9_600)
        player.pause()
        _ = try player.renderOffline(frames: 960) // the fade-out
        player.play()
        let resumed = statuses.count
        _ = try player.renderOffline(frames: 960)
        player.tick()
        #expect(statuses.count == resumed)
        _ = try player.renderOffline(frames: 4_800)
        player.tick()
        #expect(statuses.count == resumed + 1)
    }

    @Test func seekBeforePlayingStartsThere() throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(stems.result)
        player.seek(to: 0.5)
        player.play()
        _ = try player.renderOffline(frames: 480)
        player.tick()
        let head = try #require(statuses.last?.playhead)
        #expect(head >= 0.5 && head < 0.52)
    }

    @Test func pauseFadesToSilence() throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result)
        player.setGains(speechOnly)
        player.play()
        _ = try player.renderOffline(frames: 2_400)
        player.pause()
        let after = try player.renderOffline(frames: 2_400)
        #expect(after[0] > 0.4) // fading, not cut
        #expect(near(after[300...], 0, tolerance: 0))
    }

    @Test func withoutStemsItPlaysSilenceAndStillMoves() throws {
        let player = PreviewPlayer(output: .offline)
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(JobResult(output: URL(fileURLWithPath: "/nonexistent/out.wav"), stems: URL(fileURLWithPath: "/nonexistent/stems")))
        player.play()
        let samples = try player.renderOffline(frames: 48_000)
        #expect(samples.allSatisfy { $0 == 0 })
        player.tick()
        #expect(statuses.last?.isPlaying == true)
        #expect((statuses.last?.playhead ?? 0) > 0) // one of PreviewPlayer.fallbackDuration seconds
    }

    @Test func emptyStemDoesNotSilenceTheOthers() throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        // A header with no samples. The preview plays the shortest stem's length, so counting
        // it would leave zero frames and nothing to hear.
        try StemFixture.write(0.9, frames: 0, to: PreviewStem.background.url(in: stems.directory))
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result)
        player.setGains(StemGains(clean: 1, vocals: 0, background: 1, music: 0))
        player.play()
        let samples = try player.renderOffline(frames: 4_800)
        #expect(near(samples[300...], 0.5)) // clean alone, after the fade-in
    }

    @Test func unloadedPlayerIgnoresPlay() throws {
        let player = PreviewPlayer(output: .offline)
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(nil)
        player.play()
        // The model flips isPlaying before asking, so a refusal must still be reported.
        #expect(statuses.last == PlaybackStatus(isPlaying: false, playhead: 0))
        #expect(statuses.allSatisfy { !$0.isPlaying })
        #expect(try player.renderOffline(frames: 100).isEmpty)
    }

    @Test func loadingAnotherJobNeverStartsOnTheOriginal() throws {
        let first = try StemFixture()
        let second = try StemFixture()
        defer { first.remove(); second.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(first.result)
        player.setGains(speechOnly)
        player.setComparing(true) // ⌥ held when the focus changes
        player.load(second.result)
        player.play()
        let samples = try player.renderOffline(frames: 4_800)
        #expect(near(samples[300...], 0.5)) // the clean mix, not preview_original (0.3)
    }

    @Test func replacingAPlayingGraphLetsItFadeOut() async throws {
        let first = try StemFixture()
        let second = try StemFixture()
        defer { first.remove(); second.remove() }
        let player = PreviewPlayer(output: .offline)
        player.fadesOutOnReplace = true // what a device player does
        player.load(first.result)
        player.setGains(speechOnly)
        player.play()
        _ = try player.renderOffline(frames: 2_400)
        // A device player is also "audible" right after pause(), until its scheduled stop.
        player.load(second.result)
        #expect(player.retiringCount == 1)
        try await Task.sleep(for: .seconds(PreviewPlayer.stopDelay + 0.15))
        #expect(player.retiringCount == 0)

        // Loading while idle has nothing to fade.
        player.load(first.result)
        #expect(player.retiringCount == 0)
    }

    @Test func offlinePlayersReleaseAtOnce() throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result)
        player.play()
        player.load(stems.result)
        #expect(player.retiringCount == 0)
    }

    @Test func speechChangesAreLoudnessMatchedLikeSave() async throws {
        let stems = try StemFixture() // clean 0.5, vocals 0.1: constant, so every frame is "active"
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result(settings: .init()))
        await player.waitForSpeechLevel()
        let standard = Mix.standard.gains()
        player.setGains(standard)
        #expect(abs(player.speechCorrection - 1) < 1e-12)

        // Speech 0 plays the vocals stem (0.1). Remix would gain it up to the default voice's
        // active level, 0.9905·0.5 + 0.0095·0.1, and so must the preview.
        player.setGains(Mix(speech: 0, background: 0, music: 0).gains())
        let voiceAtStandard = standard.clean * 0.5 + standard.vocals * 0.1
        #expect(abs(player.speechCorrection - voiceAtStandard / 0.1) < 1e-6)
        player.play()
        let samples = try player.renderOffline(frames: 4_800)
        #expect(near(samples[300...], Float(voiceAtStandard), tolerance: 0.001))

        // The original is already level-matched: comparing ignores the correction.
        player.setComparing(true)
        let comparing = try player.renderOffline(frames: 4_800)
        #expect(near(comparing[2_000...], 0.3))
    }

    @Test func speechLevelsSurviveFocusChanges() async throws {
        let first = try StemFixture()
        let second = try StemFixture()
        defer { first.remove(); second.remove() }
        let player = PreviewPlayer(output: .offline)
        player.setGains(Mix(speech: 0, background: 0, music: 0).gains())
        // Clicking away and back before the first job's measurement lands reuses it.
        player.load(first.result(settings: .init()))
        player.load(second.result(settings: .init()))
        player.load(first.result(settings: .init()))
        await player.waitForSpeechLevel()
        #expect(player.speechLevelMeasurementCount == 2)
        #expect(player.speechCorrection > 1) // measured and applied to the focused job

        // Finished measurements are kept, whichever job was focused when they landed.
        player.load(second.result(settings: .init()))
        await player.waitForSpeechLevel()
        player.load(first.result(settings: .init()))
        #expect(player.speechCorrection > 1) // straight from the cache, no wait
        #expect(player.speechLevelMeasurementCount == 2)
    }

    @Test(arguments: [
        StemsManifest.RenderSettings(level: true),
        StemsManifest.RenderSettings(loudness: .lufs(-16)),
    ])
    func noCorrectionWhenSaveDoesNotFollowTheVoice(settings: StemsManifest.RenderSettings) async throws {
        let stems = try StemFixture()
        defer { stems.remove() }
        let player = PreviewPlayer(output: .offline)
        player.load(stems.result(settings: settings))
        await player.waitForSpeechLevel()
        player.setGains(Mix(speech: 0, background: 0, music: 0).gains())
        #expect(player.speechCorrection == 1)
    }

    /// Opt-in check against real remix output. Point `BOOTH_TEST_REMIX_DIR` at a folder holding
    /// `S/` (stems of an `enhance --stems-dir` run at the default mix) and `r<speech>.wav` files
    /// written by `booth remix S -s <speech> -o r<speech>.wav`. Prints the least-squares
    /// gain of each remix over the offline preview, which must be within ±0.1 dB.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOOTH_TEST_REMIX_DIR"] != nil))
    func previewMatchesRealRemixLoudness() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BOOTH_TEST_REMIX_DIR"]))
        let stems = folder.appendingPathComponent("S", isDirectory: true)
        let manifest = try StemsManifest.load(from: stems)
        let result = JobResult(output: folder.appendingPathComponent("o.wav"), stems: stems, music: manifest.music, manifest: manifest)
        let remixes = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("r") && $0.hasSuffix(".wav") }
            .compactMap { name in Int(name.dropFirst().dropLast(4)).map { ($0, folder.appendingPathComponent(name)) } }
            .sorted { $0.0 < $1.0 }
        #expect(!remixes.isEmpty)
        for (speech, file) in remixes {
            let player = PreviewPlayer(output: .offline)
            player.load(result)
            await player.waitForSpeechLevel()
            let mix = Mix(speech: speech, background: manifest.mix.background, music: manifest.mix.music)
            player.setGains(mix.gains(curve: manifest.curve, includeMusic: manifest.music))
            player.play()
            let saved = try MappedStem(url: file)
            let frames = saved.frameCount
            let preview = try player.renderOffline(frames: AVAudioFrameCount(frames))
            // Skip the 5 ms fade-in and compare the rest.
            var dot = 0.0, energy = 0.0, residual = 0.0
            for i in 480..<min(frames, preview.count) {
                let p = Double(preview[i]), r = Double(saved.sample(i))
                dot += p * r
                energy += p * p
            }
            let gain = dot / energy
            for i in 480..<min(frames, preview.count) {
                let d = Double(saved.sample(i)) - gain * Double(preview[i])
                residual += d * d
            }
            let gainDB = 20 * log10(gain)
            let residualDB = 10 * log10(residual / Double(frames) + 1e-30)
            print(String(format: "remix s%d vs preview: %+.3f dB (correction %+.2f dB), residual %.1f dBFS", speech, gainDB, 20 * log10(player.speechCorrection), residualDB))
            #expect(abs(gainDB) < 0.1)
        }
    }

    /// Opt-in: drives the real output device at zero gain (silent) to check the 30 Hz playhead
    /// and the end-of-file rewind. `BOOTH_TEST_AUDIO_DEVICE=1 swift test --filter devicePlayback`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOOTH_TEST_AUDIO_DEVICE"] == "1"))
    func devicePlayback() async throws {
        let stems = try StemFixture(seconds: 0.6)
        defer { stems.remove() }
        let player = PreviewPlayer(output: .device)
        var statuses: [PlaybackStatus] = []
        player.onStatusChange = { statuses.append($0) }
        player.load(stems.result)
        player.setGains(StemGains(clean: 0, vocals: 0, background: 0, music: 0))
        player.play()
        try await Task.sleep(for: .milliseconds(300))
        let midway = try #require(statuses.last)
        #expect(midway.isPlaying && midway.playhead > 0.2 && midway.playhead < 0.8)
        #expect(statuses.count > 3) // ticking
        await waitFor(3) { statuses.last == PlaybackStatus(isPlaying: false, playhead: 0) }
        #expect(statuses.last == PlaybackStatus(isPlaying: false, playhead: 0))
    }
}

@Suite("Compare key")
@MainActor
struct CompareKeyTests {
    @Test func onlyOptionAloneCompares() {
        #expect(OptionKeyMonitor.isCompareChord(.option))
        #expect(OptionKeyMonitor.isCompareChord([.option, .capsLock]))
        #expect(!OptionKeyMonitor.isCompareChord([.option, .command]))
        #expect(!OptionKeyMonitor.isCompareChord([.option, .control]))
        #expect(!OptionKeyMonitor.isCompareChord([]))
    }

    @Test func reportsChangesAndReleasesOnStop() {
        let flags = NSEventModifierFlagsBox()
        let monitor = OptionKeyMonitor { flags.value }
        var reports: [Bool] = []
        monitor.start { reports.append($0) }
        monitor.poll()
        flags.value = .option
        monitor.poll()
        monitor.poll()
        monitor.stop()
        #expect(reports == [true, false])
        flags.value = .option
        monitor.poll() // stopped: no callback
        #expect(reports == [true, false])
    }

    @Test func modelWatchesTheKeyOnlyOnAnOpenDoneScreen() async throws {
        let h = await Harness.ready()
        let key = ManualCompareKey()
        let model = AppModel(
            settings: h.settings,
            dependencies: AppDependencies(
                engine: EngineServices(locator: h.locator, jobs: h.runner, setup: h.setupRunner, remixer: h.remixer, player: h.player, compareKey: key),
                system: SystemServices(notifier: h.notifier, loginItem: h.loginItem, workspace: h.workspace)),
            stemsRoot: URL(fileURLWithPath: "/tmp/booth-tests/jobs", isDirectory: true))
        await model.checkEngine()
        model.enqueue([h.file("take.wav")])
        let active = try #require(model.activeJob)
        let output = try #require(active.output)
        model.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!key.isWatching) // Working screen

        h.runner.send(.done(EngineDone(output: output.path, took: 3, music: false)), to: active.id)
        #expect(model.effectiveScreen == .done)
        await waitFor(2) { key.isWatching }
        #expect(key.isWatching)

        key.set(held: true)
        #expect(model.isComparing)
        key.set(held: false)
        #expect(!model.isComparing)

        key.set(held: true)
        model.close()
        #expect(!model.isComparing)
        await waitFor(2) { !key.isWatching }
        #expect(!key.isWatching)
    }
}

/// Mutable flags the monitor's reader closure can see.
@MainActor
final class NSEventModifierFlagsBox {
    var value: NSEvent.ModifierFlags = []
}
