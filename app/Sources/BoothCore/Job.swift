import Foundation

/// Lifecycle of one file in the booth.
public enum JobState: String, Sendable, CaseIterable {
    case queued, working, done, failed, cancelled

    /// No further engine events change a finished job.
    public var isFinished: Bool {
        switch self {
        case .queued, .working: false
        case .done, .failed, .cancelled: true
        }
    }
}

/// An engine `error` event, or a failure the app detected itself.
public struct JobError: Error, Equatable, Sendable {
    /// Error codes from SPEC §1.3. A struct rather than an enum so codes added by a newer
    /// engine still round-trip.
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public var description: String { rawValue }

        public static let notFound: Code = "not_found"
        public static let noAudio: Code = "no_audio"
        public static let decodeFailed: Code = "decode_failed"
        public static let engineFailed: Code = "engine_failed"
        public static let cancelled: Code = "cancelled"
        public static let setupRequired: Code = "setup_required"
        public static let `internal`: Code = "internal"
        public static let setupFailed: Code = "setup_failed"
    }

    public var code: Code
    /// A human sentence, shown in the popover.
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    /// The engine's canonical no-audio error, also used by the demo runner.
    public static func noAudio(fileName: String) -> JobError {
        JobError(code: .noAudio, message: "\(fileName) has a video track but no sound. Nothing was changed.")
    }
}

extension JobError: Decodable {
    private enum CodingKeys: String, CodingKey {
        case code, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = Code(rawValue: try c.decodeIfPresent(String.self, forKey: .code) ?? Code.internal.rawValue)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// What a finished job produced.
public struct JobResult: Equatable, Sendable {
    /// The file the user cares about: the video when there is one, else the wav.
    public var output: URL
    public var wav: URL?
    public var video: URL?
    /// Preview stems directory; nil when the engine ran without `--stems-dir` (and in demo mode).
    public var stems: URL?
    /// Processing time in seconds.
    public var took: Double
    /// Music was detected; the Done screen hides the Music slider otherwise.
    public var music: Bool
    /// The mix the output was rendered with.
    public var mix: Mix
    /// Loaded from `stems/manifest.json` by the app once the job is done.
    public var manifest: StemsManifest?

    public init(
        output: URL, wav: URL? = nil, video: URL? = nil, stems: URL? = nil, took: Double = 0,
        music: Bool = false, mix: Mix = .standard, manifest: StemsManifest? = nil
    ) {
        self.output = output
        self.wav = wav
        self.video = video
        self.stems = stems
        self.took = took
        self.music = music
        self.mix = mix
        self.manifest = manifest
    }

    /// nil when the event names no output file.
    public init?(done: EngineDone) {
        guard let output = done.output, !output.isEmpty else { return nil }
        self.init(
            output: URL(fileURLWithPath: output),
            wav: done.wav.map { URL(fileURLWithPath: $0) },
            video: done.video.map { URL(fileURLWithPath: $0) },
            stems: done.stems.map { URL(fileURLWithPath: $0, isDirectory: true) },
            took: done.took ?? 0,
            music: done.music,
            mix: done.mix ?? .standard)
    }

    /// The bars to draw: the manifest's when there is one, else a synthetic shape.
    public var waveformSource: StemsManifest.Bars {
        manifest?.bars ?? .synthetic(music: music)
    }

    public var curve: MixCurve { manifest?.curve ?? .standard }
}

/// One file in the queue.
public struct Job: Identifiable, Equatable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public let input: URL
    /// Display name: the input's file name.
    public var name: String
    public var state: JobState
    /// 0…1, never decreases.
    public var progress: Double
    /// Current stage label ("Restoring the voice"); empty until the first progress event.
    public var stageLabel: String
    /// Seconds remaining, as last reported by the engine.
    public var eta: Double?
    /// Media duration in seconds, from the `start` event.
    public var duration: Double?
    /// "3:12 · MP4 · 1080p", from the `start` event.
    public var meta: String?
    public var hasVideo: Bool
    /// Where the output goes; decided by the app when the job starts.
    public var output: URL?
    public var result: JobResult?
    public var error: JobError?
    public let enqueuedAt: Date
    public var startedAt: Date?

    public init(id: ID = UUID(), input: URL, state: JobState = .queued, enqueuedAt: Date = Date()) {
        self.id = id
        self.input = input
        self.name = input.lastPathComponent
        self.state = state
        self.progress = 0
        self.stageLabel = ""
        self.eta = nil
        self.duration = nil
        self.meta = nil
        self.hasVideo = OutputNaming.mediaKind(of: input) == .video
        self.output = nil
        self.result = nil
        self.error = nil
        self.enqueuedAt = enqueuedAt
        self.startedAt = nil
    }

    public var mediaKind: MediaKind? { OutputNaming.mediaKind(of: input) }

    /// Folds one engine event into the job. Events after the job finished are ignored.
    public mutating func apply(_ event: EngineEvent) {
        guard !state.isFinished else { return }
        switch event {
        case .start(let start):
            state = .working
            if let duration = start.duration { self.duration = duration }
            if let meta = start.meta, !meta.isEmpty { self.meta = meta }
            hasVideo = start.hasVideo
            if let eta = start.eta { self.eta = eta }

        case .progress(let update):
            state = .working
            progress = max(progress, min(1, max(0, update.progress)))
            if let label = update.label, !label.isEmpty { stageLabel = label }
            if let eta = update.eta { self.eta = max(0, eta) }

        case .done(let done):
            guard let result = JobResult(done: done) else {
                fail(JobError(code: .engineFailed, message: "The engine finished without writing a file."))
                return
            }
            self.result = result
            state = .done
            progress = 1
            eta = 0

        case .error(let error):
            fail(error)

        case .hello, .info, .setup, .setupStatus, .unknown:
            break
        }
    }

    private mutating func fail(_ error: JobError) {
        self.error = error
        state = error.code == .cancelled ? .cancelled : .failed
    }
}
