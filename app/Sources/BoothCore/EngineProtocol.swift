import Foundation

// The engine speaks JSON Lines on stdout (SPEC §1): one object per line, each with an
// "event" key. Readers ignore unknown keys and unknown events so that a newer engine never
// breaks an older app.

/// One decoded line of the engine's event stream.
public enum EngineEvent: Equatable, Sendable {
    case hello(EngineHello)
    case start(EngineStart)
    case progress(EngineProgress)
    case done(EngineDone)
    case error(JobError)
    case info(EngineInfo)
    case setup(SetupProgress)
    case setupStatus(SetupStatus)
    /// An event this app does not know about. Callers ignore it.
    case unknown(name: String)
}

/// The protocol version this app speaks. `app-info` must report the same number.
public let engineProtocolVersion = 1

/// `{"event":"hello","protocol":1,"version":"0.1.0"}`
public struct EngineHello: Equatable, Sendable {
    public var protocolVersion: Int
    public var version: String

    public init(protocolVersion: Int = engineProtocolVersion, version: String = "") {
        self.protocolVersion = protocolVersion
        self.version = version
    }
}

/// `{"event":"start", ...}` — the engine has probed the input and is about to process it.
public struct EngineStart: Equatable, Sendable {
    public var input: String?
    public var name: String?
    public var duration: Double?
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Ready-made display string, e.g. "3:12 · MP4 · 1080p".
    public var meta: String?
    public var engine: String?
    public var eta: Double?

    public init(
        input: String? = nil, name: String? = nil, duration: Double? = nil,
        hasVideo: Bool = false, hasAudio: Bool = true, meta: String? = nil,
        engine: String? = nil, eta: Double? = nil
    ) {
        self.input = input
        self.name = name
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.meta = meta
        self.engine = engine
        self.eta = eta
    }
}

/// `{"event":"progress","progress":0.52,"stage":"restore","label":"Restoring the voice","eta":61.0}`
public struct EngineProgress: Equatable, Sendable {
    /// Overall fraction 0…1, monotonic.
    public var progress: Double
    public var stage: String?
    public var label: String?
    /// Seconds remaining.
    public var eta: Double?

    public init(progress: Double, stage: String? = nil, label: String? = nil, eta: Double? = nil) {
        self.progress = progress
        self.stage = stage
        self.label = label
        self.eta = eta
    }
}

/// `{"event":"done", ...}`. Every field is optional because `setup` and `remix` reuse the
/// event: setup sends a bare `{"event":"done"}`.
public struct EngineDone: Equatable, Sendable {
    public var output: String?
    public var wav: String?
    public var video: String?
    public var stems: String?
    public var took: Double?
    public var music: Bool
    public var mix: Mix?

    public init(
        output: String? = nil, wav: String? = nil, video: String? = nil, stems: String? = nil,
        took: Double? = nil, music: Bool = false, mix: Mix? = nil
    ) {
        self.output = output
        self.wav = wav
        self.video = video
        self.stems = stems
        self.took = took
        self.music = music
        self.mix = mix
    }
}

/// `booth app-info` →
/// `{"event":"info","protocol":1,"version":"0.1.0","engines":[...],"ready":true,"missing":[],"python":"/abs/python"}`
public struct EngineInfo: Equatable, Sendable {
    public var protocolVersion: Int
    public var version: String
    public var engines: [String]
    public var ready: Bool
    public var missing: [String]
    public var python: String?

    public init(
        protocolVersion: Int = engineProtocolVersion, version: String = "", engines: [String] = [],
        ready: Bool = false, missing: [String] = [], python: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.version = version
        self.engines = engines
        self.ready = ready
        self.missing = missing
        self.python = python
    }
}

/// `{"event":"setup","phase":"weights","label":"Downloading voice models","bytes_done":N,"bytes_total":M,"eta":s,"progress":0.37}`
public struct SetupProgress: Equatable, Sendable {
    public var phase: String?
    public var label: String?
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var eta: Double?
    /// Overall 0…1 when the engine reports it. It also moves while the engine installs its
    /// Sidon environment, when no bytes are counted yet, so it beats the byte ratio.
    public var progress: Double?

    public init(
        phase: String? = nil, label: String? = nil, bytesDone: Int64 = 0, bytesTotal: Int64 = 0,
        eta: Double? = nil, progress: Double? = nil
    ) {
        self.phase = phase
        self.label = label
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.eta = eta
        self.progress = progress
    }
}

/// `booth setup --events --check` → `{"event":"setup_status","ready":false,"missing":[...],"bytes_total":N}`
public struct SetupStatus: Equatable, Sendable {
    public var ready: Bool
    public var missing: [String]
    public var bytesTotal: Int64

    public init(ready: Bool, missing: [String] = [], bytesTotal: Int64 = 0) {
        self.ready = ready
        self.missing = missing
        self.bytesTotal = bytesTotal
    }
}

// MARK: - Decoding

/// Turns one stdout line into an `EngineEvent`. Returns nil for anything that is not a JSON
/// object with a string `"event"` key, or for a known event whose fields have the wrong types.
public enum EngineEventDecoder {
    public static func decode(line: String) -> EngineEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        return decode(Data(trimmed.utf8))
    }

    public static func decode(_ data: Data) -> EngineEvent? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        do {
            switch envelope.event {
            case "hello": return .hello(try decoder.decode(EngineHello.self, from: data))
            case "start": return .start(try decoder.decode(EngineStart.self, from: data))
            case "progress": return .progress(try decoder.decode(EngineProgress.self, from: data))
            case "done": return .done(try decoder.decode(EngineDone.self, from: data))
            case "error": return .error(try decoder.decode(JobError.self, from: data))
            case "info": return .info(try decoder.decode(EngineInfo.self, from: data))
            case "setup": return .setup(try decoder.decode(SetupProgress.self, from: data))
            case "setup_status": return .setupStatus(try decoder.decode(SetupStatus.self, from: data))
            default: return .unknown(name: envelope.event)
            }
        } catch {
            return nil
        }
    }

    private struct Envelope: Decodable {
        let event: String
    }
}

/// Splits a byte stream (a pipe read in arbitrary chunks) into complete lines.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Appends a chunk and returns every line it completed, without the terminator.
    /// Accepts `\n` and `\r\n`. Invalid UTF-8 is repaired rather than dropped.
    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = pending[pending.startIndex..<newline]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// Returns the unterminated tail, if any, and empties the buffer. Call at end of stream.
    public mutating func finish() -> String? {
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return nil }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// A pipeline stage and its default share of the run (SPEC §1.3). The engine reports stages
/// itself; the app uses this table only to simulate them (demo, fixtures).
public struct EngineStage: Equatable, Sendable {
    public var id: String
    public var label: String
    public var weight: Double

    public init(id: String, label: String, weight: Double) {
        self.id = id
        self.label = label
        self.weight = weight
    }

    /// Sidon with music separation.
    public static let studio: [EngineStage] = [
        EngineStage(id: "decode", label: "Reading audio", weight: 0.03),
        EngineStage(id: "separate", label: "Separating music", weight: 0.40),
        EngineStage(id: "restore", label: "Restoring the voice", weight: 0.40),
        EngineStage(id: "cleanup", label: "Removing clicks", weight: 0.10),
        EngineStage(id: "write", label: "Writing the file", weight: 0.07),
    ]

    /// The stages a run goes through, weights renormalised over the ones that actually run.
    public static func plan(engine: EngineChoice, splitMusic: Bool) -> [EngineStage] {
        let stages = studio.compactMap { stage -> EngineStage? in
            if stage.id == "separate" && !splitMusic { return nil }
            var stage = stage
            if engine != .studio {
                if stage.id == "restore" { stage.label = "Removing noise" }
                if stage.id == "cleanup" { stage.label = "Cleaning up" }
            }
            return stage
        }
        let total = stages.reduce(0) { $0 + $1.weight }
        return stages.map { EngineStage(id: $0.id, label: $0.label, weight: $0.weight / total) }
    }

    /// The stage running at overall `progress` (the prototype's cumulative-weight lookup).
    public static func stage(at progress: Double, in stages: [EngineStage]) -> EngineStage? {
        var start = 0.0
        var current = stages.first
        for stage in stages {
            if progress >= start { current = stage }
            start += stage.weight
        }
        return current
    }
}

// MARK: - Invocation (SPEC §1.6)

/// The three engines, as the user sees them in Settings.
public enum EngineChoice: String, CaseIterable, Codable, Sendable {
    case studio, clean, quick

    /// The `--engine` value the CLI expects.
    public var engineName: String {
        switch self {
        case .studio: "sidon"
        case .clean: "mossformer2"
        case .quick: "df3"
        }
    }

    public var label: String {
        switch self {
        case .studio: "Studio"
        case .clean: "Clean"
        case .quick: "Quick"
        }
    }

    /// The line under the segmented control in Settings.
    public var note: String {
        switch self {
        case .studio: "Rebuilds the voice at 48 kHz. Best quality, about half real time."
        case .clean: "Removes noise without rebuilding the voice. Faster."
        case .quick: "Light noise removal in seconds. Good for drafts."
        }
    }

    public init?(engineName: String) {
        guard let match = Self.allCases.first(where: { $0.engineName == engineName }) else { return nil }
        self = match
    }
}

/// Everything the app decides about one enhance run.
public struct RunOptions: Equatable, Sendable {
    public var output: URL
    /// Per-job cache directory; the runner creates it and uses it as the working directory.
    public var stemsDirectory: URL
    public var engine: EngineChoice
    /// false → `--no-split` (skip music separation).
    public var splitMusic: Bool
    /// false → `--audio-only`. A `.wav` output gets `--audio-only` too (see `arguments`).
    public var keepVideo: Bool
    public var mix: Mix

    public init(
        output: URL, stemsDirectory: URL, engine: EngineChoice = .studio,
        splitMusic: Bool = true, keepVideo: Bool = true, mix: Mix = .standard
    ) {
        self.output = output
        self.stemsDirectory = stemsDirectory
        self.engine = engine
        self.splitMusic = splitMusic
        self.keepVideo = keepVideo
        self.mix = mix
    }

    /// Arguments after the engine executable:
    /// `enhance <input> --events --stems-dir <dir> -o <output> --engine <name> [--no-split] [--audio-only] -s S -b B -m M`
    ///
    /// `--audio-only` goes with `keepVideo == false` and with every `.wav` output. A `.wav` output
    /// means the app reserved only that name, but an audio-extension input (`.m4a`, `.mka`, …)
    /// can still carry a video stream, and without the flag the engine would remux into
    /// `<stem>-enhanced.<input ext>` next to it, a name nobody reserved.
    public func arguments(input: URL) -> [String] {
        var args = [
            "enhance", input.path, "--events",
            "--stems-dir", stemsDirectory.path,
            "-o", output.path,
            "--engine", engine.engineName,
        ]
        if !splitMusic { args.append("--no-split") }
        if !keepVideo || output.pathExtension.lowercased() == "wav" { args.append("--audio-only") }
        args += ["-s", String(mix.speech), "-b", String(mix.background), "-m", String(mix.music)]
        return args
    }
}

// MARK: - Codable conformances (snake_case wire format)

extension EngineHello: Decodable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeLenientInt(.protocolVersion) ?? engineProtocolVersion
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
    }
}

extension EngineStart: Decodable {
    private enum CodingKeys: String, CodingKey {
        case input, name, duration, hasVideo = "has_video", hasAudio = "has_audio", meta, engine, eta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(String.self, forKey: .input)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        meta = try c.decodeIfPresent(String.self, forKey: .meta)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        eta = try c.decodeIfPresent(Double.self, forKey: .eta)
    }
}

extension EngineProgress: Decodable {
    private enum CodingKeys: String, CodingKey {
        case progress, stage, label, eta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        progress = try c.decode(Double.self, forKey: .progress)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        eta = try c.decodeIfPresent(Double.self, forKey: .eta)
    }
}

extension EngineDone: Decodable {
    private enum CodingKeys: String, CodingKey {
        case output, wav, video, stems, took, music, mix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        wav = try c.decodeIfPresent(String.self, forKey: .wav)
        video = try c.decodeIfPresent(String.self, forKey: .video)
        stems = try c.decodeIfPresent(String.self, forKey: .stems)
        took = try c.decodeIfPresent(Double.self, forKey: .took)
        music = try c.decodeIfPresent(Bool.self, forKey: .music) ?? false
        mix = try c.decodeIfPresent(Mix.self, forKey: .mix)
    }
}

extension EngineInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", version, engines, ready, missing, python
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let version: Int = try c.decodeLenientInt(.protocolVersion) else {
            throw DecodingError.keyNotFound(
                CodingKeys.protocolVersion,
                .init(codingPath: c.codingPath, debugDescription: "info without a protocol version"))
        }
        protocolVersion = version
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        engines = try c.decodeIfPresent([String].self, forKey: .engines) ?? []
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
        python = try c.decodeIfPresent(String.self, forKey: .python)
    }
}

extension SetupProgress: Decodable {
    private enum CodingKeys: String, CodingKey {
        case phase, label, bytesDone = "bytes_done", bytesTotal = "bytes_total", eta, progress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        bytesDone = try c.decodeLenientInt(.bytesDone) ?? 0
        bytesTotal = try c.decodeLenientInt(.bytesTotal) ?? 0
        eta = try c.decodeIfPresent(Double.self, forKey: .eta)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
    }
}

extension SetupStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case ready, missing, bytesTotal = "bytes_total"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ready = try c.decode(Bool.self, forKey: .ready)
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
        bytesTotal = try c.decodeLenientInt(.bytesTotal) ?? 0
    }
}

extension KeyedDecodingContainer {
    /// Decodes an integer that a Python writer may have emitted as `1.13e9` or `412.0`.
    /// Missing or null → nil; a non-numeric value throws.
    func decodeLenientInt<T: FixedWidthInteger & Decodable>(_ key: Key) throws -> T? {
        if let exact = try? decodeIfPresent(T.self, forKey: key) { return exact }
        guard let real = try decodeIfPresent(Double.self, forKey: key) else { return nil }
        guard real.isFinite, let value = T(exactly: real.rounded()) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(real) is not an integer")
        }
        return value
    }
}
