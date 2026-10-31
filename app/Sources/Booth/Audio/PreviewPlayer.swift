import AVFoundation
import BoothCore
import Foundation

/// Plays a finished job's preview stems with live mix gains (SPEC §2.4).
///
/// One `AVAudioSourceNode` pulls from `PreviewMixer`, which sums the memory-mapped stems with the
/// current gains: sliders change the sound immediately, holding ⌥ swaps to the loudness-matched
/// original, and the playhead is published at 30 Hz. Files are mapped on the first `play()`,
/// and a job without stems plays silence for its duration instead of failing.
///
/// Save re-applies auto gain for the new Speech setting, so the enhanced stems are scaled by the
/// same correction (`SpeechLevel`), measured off the main thread when a job loads; until then,
/// and for jobs whose loudness isn't auto or that ran the leveler, the factor is 1.
///
/// The published playhead is what you hear, not what was just rendered: the video picture
/// follows it, and a Bluetooth output plays a rendered sample 0.1–0.3 s later.
@MainActor
final class PreviewPlayer: PreviewPlaying {
    enum Output {
        /// The default output device.
        case device
        /// No device: tests pull samples with `renderOffline(frames:)`.
        case offline
    }

    var onStatusChange: (@MainActor (PlaybackStatus) -> Void)?

    static let tickInterval: TimeInterval = 1.0 / 30
    /// Lets the fade-out render before the engine stops after a pause.
    static let stopDelay: TimeInterval = 0.08
    /// The silent stand-in length for a job without stems.
    static let fallbackDuration: Double = 12
    /// The most output latency the playhead allows for (seconds). Bluetooth reports 0.1–0.3 s;
    /// a larger figure is more likely a misreport, and would hold the playhead still after Play.
    static let maxOutputLatency: TimeInterval = 0.5

    private let output: Output
    private var result: JobResult?
    private var gains = Mix.standard.gains()
    private var comparing = false
    private var status = PlaybackStatus(isPlaying: false, playhead: 0)
    /// Where to start once the graph exists (a seek before the first play).
    private var pendingFraction: Double = 0
    /// How long a rendered sample takes to be heard (seconds): the output's latency plus one I/O
    /// buffer. Read when playback starts and when the output device changes; offline it stays
    /// at whatever a test sets.
    var outputLatency: TimeInterval = 0
    /// The frame playback last started or jumped from. Until the output latency has passed, what
    /// you hear is still the sound from before, so the playhead waits here rather than run back.
    private var heardFloor = 0

    private var graph: Graph?
    private var ticker: Timer?
    private var pendingStop: DispatchWorkItem?
    /// Graphs replaced while audible, kept alive for `stopDelay` so their fade-out renders
    /// before the engine stops (a focus change mid-preview must not click).
    private var retiring: [Graph] = []
    /// Fade the old graph out on `load` instead of stopping it at once. Always for the device;
    /// offline players release at once unless a test turns this on.
    var fadesOutOnReplace: Bool

    /// The loaded job's Speech loudness data, once measured; measured once per stems folder.
    private var speechLevel: SpeechLevel?
    private var speechLevels: [String: SpeechLevel] = [:]
    /// Measurements still running, by stems folder.
    private var speechLevelMeasurements: [String: Task<SpeechLevel?, Never>] = [:]
    private var speechLevelTask: Task<Void, Never>?
    /// `activeSpeechDB` per Speech gain for the loaded job (the sliders revisit the same values).
    private var speechDBMemo: [Double: Double] = [:]

    private final class Graph {
        let engine = AVAudioEngine()
        let mixer: PreviewMixer
        let node: AVAudioSourceNode
        var configurationObserver: NSObjectProtocol?

        init(mixer: PreviewMixer, format: AVAudioFormat) {
            self.mixer = mixer
            node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                mixer.render(into: first, count: Int(frameCount))
                for extra in buffers.dropFirst() {
                    extra.mData?.copyMemory(from: first, byteCount: Int(frameCount) * MemoryLayout<Float>.size)
                }
                return noErr
            }
        }

        /// Stops reacting to device changes, so a graph on its way out is never restarted.
        func detach() {
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
        }

        deinit {
            detach()
            engine.stop()
        }
    }

    init(output: Output = .device) {
        self.output = output
        if case .device = output { fadesOutOnReplace = true } else { fadesOutOnReplace = false }
    }

    // MARK: - PreviewPlaying

    func load(_ result: JobResult?) {
        teardown()
        self.result = result
        // A new job never starts on the original, whatever the last one was doing.
        comparing = false
        pendingFraction = 0
        prepareSpeechLevel(for: result)
        publish(PlaybackStatus(isPlaying: false, playhead: 0))
    }

    func play() {
        guard !status.isPlaying else { return }
        guard result != nil, let graph = graph ?? buildGraph() else {
            reportPaused()
            return
        }
        pendingStop?.cancel()
        pendingStop = nil
        if status.playhead >= 1 { seek(to: 0) }
        graph.mixer.setPlaying(true)
        guard startEngine(graph) else {
            graph.mixer.setPlaying(false)
            reportPaused()
            return
        }
        updateOutputLatency(graph)
        heardFloor = graph.mixer.position().frame
        startTicking()
        publish(PlaybackStatus(isPlaying: true, playhead: status.playhead))
    }

    func pause() {
        guard status.isPlaying else { return }
        graph?.mixer.setPlaying(false)
        stopTicking()
        publish(PlaybackStatus(isPlaying: false, playhead: currentFraction()))
        scheduleEngineStop()
    }

    func seek(to fraction: Double) {
        let clamped = min(1, max(0, fraction))
        if let graph {
            let frame = Int((clamped * Double(graph.mixer.frameCount)).rounded())
            graph.mixer.seek(toFrame: frame)
            heardFloor = frame
        } else {
            pendingFraction = clamped
        }
        publish(PlaybackStatus(isPlaying: status.isPlaying, playhead: clamped))
    }

    func setGains(_ gains: StemGains) {
        self.gains = gains
        pushTargets()
    }

    func setComparing(_ comparing: Bool) {
        self.comparing = comparing
        pushTargets()
    }

    // MARK: - Ticking

    /// Publishes the playhead and notices the end. Runs at 30 Hz while playing; tests call it
    /// directly.
    func tick() {
        guard let graph, status.isPlaying else { return }
        let position = graph.mixer.position()
        if position.reachedEnd {
            graph.mixer.setPlaying(false)
            graph.mixer.seek(toFrame: 0)
            stopTicking()
            publish(PlaybackStatus(isPlaying: false, playhead: 0))
            scheduleEngineStop()
            return
        }
        let latency = Int((outputLatency * graph.mixer.sampleRate).rounded())
        // Until the new sound is heard, keep the playhead play, pause or seek published, exactly:
        // a value that differs only by rounding or a fade-out would start the video early.
        let heard = position.frame - latency
        guard heard > heardFloor else { return }
        publish(PlaybackStatus(isPlaying: true, playhead: fraction(of: heard, in: graph.mixer)))
    }

    // MARK: - Test seams

    /// Graphs still fading out after a `load`.
    var retiringCount: Int { retiring.count }

    /// Waits for the Speech loudness measurement started by the last `load`.
    func waitForSpeechLevel() async {
        await speechLevelTask?.value
    }

    /// Speech loudness measurements started: one per job, however often it is focused.
    private(set) var speechLevelMeasurementCount = 0

    /// The factor the enhanced stems are scaled by right now.
    var speechCorrection: Double { currentSpeechCorrection() }

    // MARK: - Offline rendering (tests)

    /// Pulls `frames` samples through the engine. Only for `.offline` players that are playing
    /// or paused after a `play()`.
    func renderOffline(frames: AVAudioFrameCount) throws -> [Float] {
        guard case .offline = output, let graph else { return [] }
        let engine = graph.engine
        if !engine.isRunning { try engine.start() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(Int(frames))
        while samples.count < Int(frames) {
            let chunk = min(engine.manualRenderingMaximumFrameCount, frames - AVAudioFrameCount(samples.count))
            let status = try engine.renderOffline(chunk, to: buffer)
            guard status == .success, let channel = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }

    // MARK: - Private

    private func buildGraph() -> Graph? {
        guard let result else { return nil }
        let (stems, sampleRate) = Self.mapStems(of: result)
        let duration = result.manifest?.duration ?? Self.fallbackDuration
        let mixer = PreviewMixer(
            stems: stems, sampleRate: sampleRate, fallbackDuration: duration > 0 ? duration : Self.fallbackDuration,
            targets: currentTargets())
        guard let format = AVAudioFormat(standardFormatWithSampleRate: mixer.sampleRate, channels: 1) else {
            Log.error("preview: no audio format for \(mixer.sampleRate) Hz")
            return nil
        }
        let graph = Graph(mixer: mixer, format: format)
        let engine = graph.engine
        do {
            if case .offline = output {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            }
            engine.attach(graph.node)
            engine.connect(graph.node, to: engine.mainMixerNode, format: format)
        } catch {
            Log.error("preview: could not build the audio graph: \(error.localizedDescription)")
            return nil
        }
        graph.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioConfigurationDidChange() }
        }
        if pendingFraction > 0 { mixer.seek(toFrame: Int((pendingFraction * Double(mixer.frameCount)).rounded())) }
        self.graph = graph
        Log.info("preview: \(stems.count) stem(s), \(mixer.frameCount) frames at \(Int(sampleRate)) Hz")
        return graph
    }

    /// Maps every preview stem that exists and agrees with the first one's sample rate.
    private static func mapStems(of result: JobResult) -> ([PreviewStem: MappedStem], Double) {
        let fallbackRate = Double(result.manifest?.sampleRate ?? 48_000)
        guard let directory = result.stems else {
            Log.info("preview: \(result.output.lastPathComponent) has no stems; playing silence")
            return ([:], fallbackRate)
        }
        var stems: [PreviewStem: MappedStem] = [:]
        var sampleRate: Double?
        for role in PreviewStem.allCases {
            let url = role.url(in: directory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let stem = try MappedStem(url: url)
                // The mixer plays the shortest stem's length; an empty one would leave nothing
                // valid to read.
                guard stem.frameCount > 0 else {
                    Log.error("preview: \(url.lastPathComponent) has no samples; skipped")
                    continue
                }
                if let sampleRate, stem.sampleRate != sampleRate {
                    Log.error("preview: \(url.lastPathComponent) is \(stem.sampleRate) Hz, not \(sampleRate) Hz; skipped")
                    continue
                }
                sampleRate = stem.sampleRate
                stems[role] = stem
            } catch {
                Log.error("preview: \(error)")
            }
        }
        if stems.isEmpty { Log.info("preview: no readable stems in \(directory.path); playing silence") }
        return (stems, sampleRate ?? fallbackRate)
    }

    private func startEngine(_ graph: Graph) -> Bool {
        guard !graph.engine.isRunning else { return true }
        do {
            try graph.engine.start()
            return true
        } catch {
            Log.error("preview: audio engine did not start: \(error.localizedDescription)")
            return false
        }
    }

    private func scheduleEngineStop() {
        pendingStop?.cancel()
        guard case .device = output, let graph else { return }
        let stop = DispatchWorkItem { [weak graph] in graph?.engine.pause() }
        pendingStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopDelay, execute: stop)
    }

    private func teardown() {
        stopTicking()
        // Playing, or paused with the fade-out not yet rendered (pause schedules the stop).
        let audible = status.isPlaying || pendingStop != nil
        pendingStop?.cancel()
        pendingStop = nil
        guard let old = graph else { return }
        graph = nil
        guard audible && fadesOutOnReplace else { return } // Graph.deinit stops the engine and unmaps the stems
        old.mixer.setPlaying(false)
        old.detach()
        retiring.append(old)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.retiring.removeAll { $0 === old } // its deinit stops the engine after the fade
            }
        }
    }

    private func audioConfigurationDidChange() {
        // The output device changed (headphones, sample rate) and the engine stopped itself.
        guard let graph, status.isPlaying else { return }
        Log.info("preview: audio configuration changed; restarting")
        guard startEngine(graph) else {
            pause()
            return
        }
        // The new device starts empty and may lag more or less than the old one.
        updateOutputLatency(graph)
        heardFloor = graph.mixer.position().frame
    }

    /// Reads the output's presentation latency and I/O buffer. Leaves out the device's safety
    /// offset and where it is in its I/O cycle, so the playhead may lead the sound by a few
    /// milliseconds but never trails it.
    private func updateOutputLatency(_ graph: Graph) {
        guard case .device = output else { return }
        let node = graph.engine.outputNode
        var latency = node.presentationLatency
        var bufferFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let deviceRate = node.outputFormat(forBus: 0).sampleRate
        if let unit = node.audioUnit, deviceRate > 0,
           AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &bufferFrames, &size) == noErr {
            latency += Double(bufferFrames) / deviceRate
        }
        latency = latency.isFinite ? min(max(0, latency), Self.maxOutputLatency) : 0
        if latency != outputLatency { Log.info("preview: output latency \(Int((latency * 1000).rounded())) ms") }
        outputLatency = latency
    }

    private func pushTargets() {
        graph?.mixer.setTargets(currentTargets())
    }

    private func currentTargets() -> PreviewMixer.Gains {
        PreviewMixer.Gains(gains, comparing: comparing, enhancedScale: currentSpeechCorrection())
    }

    // MARK: - Speech loudness

    /// Measures the loaded job's clean and vocals stems in the background, when Save would
    /// re-apply auto gain from the voice alone (loudness auto, no leveler). A measurement is kept
    /// when the focus moves on before it finishes, and coming back to a job mid-measurement waits
    /// for that one rather than starting another.
    private func prepareSpeechLevel(for result: JobResult?) {
        speechLevelTask = nil
        speechLevel = nil
        speechDBMemo = [:]
        guard let result, let manifest = result.manifest, let stems = result.stems,
              manifest.settings.loudness == .auto, !manifest.settings.level else { return }
        let key = stems.standardizedFileURL.path
        if let cached = speechLevels[key] {
            speechLevel = cached
            return
        }
        let measurement: Task<SpeechLevel?, Never>
        if let running = speechLevelMeasurements[key] {
            measurement = running
        } else {
            let clean = PreviewStem.clean.url(in: stems)
            let vocals = PreviewStem.vocals.url(in: stems)
            measurement = Task.detached(priority: .utility) {
                Self.measureSpeechLevel(clean: clean, vocals: vocals)
            }
            speechLevelMeasurements[key] = measurement
            speechLevelMeasurementCount += 1
        }
        speechLevelTask = Task { [weak self] in
            let measured = await measurement.value
            guard let self else { return }
            if speechLevelMeasurements[key] == measurement { speechLevelMeasurements[key] = nil }
            guard let measured else { return }
            speechLevels[key] = measured
            guard self.result?.stems?.standardizedFileURL.path == key else { return }
            speechLevel = measured
            pushTargets()
        }
    }

    /// One sequential pass over both stems (about 72 000 frames per hour of audio).
    private nonisolated static func measureSpeechLevel(clean: URL, vocals: URL) -> SpeechLevel? {
        do {
            let c = try MappedStem(url: clean)
            let v = try MappedStem(url: vocals)
            guard c.sampleRate == v.sampleRate else {
                Log.error("preview: \(clean.lastPathComponent) and \(vocals.lastPathComponent) differ in sample rate; no Speech loudness correction")
                return nil
            }
            var level = SpeechLevel(sampleRate: c.sampleRate)
            for frame in 0..<min(c.frameCount, v.frameCount) {
                level.add(clean: c.sample(frame), vocals: v.sample(frame))
            }
            return level
        } catch {
            Log.error("preview: no Speech loudness correction: \(error)")
            return nil
        }
    }

    /// 1 at the mix the job was enhanced at (the app always enhances at `Mix.standard`, which is
    /// what the preview gain G0 was computed for), else what remix's auto gain will change.
    private func currentSpeechCorrection() -> Double {
        guard let speechLevel, let result else { return 1 }
        let reference = Mix.standard.gains(curve: result.curve).clean
        guard let referenceDB = speechDB(reference, in: speechLevel),
              let currentDB = speechDB(gains.clean, in: speechLevel) else { return 1 }
        return SpeechLevel.correction(
            referenceDB: referenceDB, currentDB: currentDB, previewGain: result.manifest?.previewGain ?? 1)
    }

    private func speechDB(_ speechGain: Double, in level: SpeechLevel) -> Double? {
        if let memo = speechDBMemo[speechGain] { return memo }
        let db = level.activeSpeechDB(speechGain: speechGain)
        if let db { speechDBMemo[speechGain] = db }
        return db
    }

    private func currentFraction() -> Double {
        guard let graph else { return status.playhead }
        return fraction(of: graph.mixer.position().frame, in: graph.mixer)
    }

    private func fraction(of frame: Int, in mixer: PreviewMixer) -> Double {
        min(1, max(0, Double(frame) / Double(max(1, mixer.frameCount))))
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Tells the model playback did not start, even though nothing changed here: it flips
    /// `isPlaying` before asking.
    private func reportPaused() {
        status.isPlaying = false
        onStatusChange?(status)
    }

    private func publish(_ new: PlaybackStatus) {
        guard new != status else { return }
        status = new
        onStatusChange?(new)
    }
}
