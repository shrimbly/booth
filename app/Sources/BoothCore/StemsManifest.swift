import Foundation

/// `DIR/manifest.json` written next to the preview stems by `enhance --stems-dir DIR` (SPEC §1.4).
/// It is what lets the app play, re-mix and re-save a finished job without the engine.
public struct StemsManifest: Codable, Equatable, Sendable {
    public static let fileName = "manifest.json"

    public var protocolVersion: Int
    public var input: String
    public var name: String
    public var duration: Double
    public var hasVideo: Bool
    public var engine: String
    public var generative: Bool
    public var music: Bool
    public var sampleRate: Int
    public var outputs: Outputs
    public var mix: Mix
    public var settings: RenderSettings
    /// Linear auto gain (G0) already applied to the preview stems.
    public var previewGain: Double
    public var bars: Bars

    public struct Outputs: Codable, Equatable, Sendable {
        public var wav: String
        public var video: String?

        public init(wav: String, video: String? = nil) {
            self.wav = wav
            self.video = video
        }
    }

    public struct RenderSettings: Codable, Equatable, Sendable {
        /// `--linear`: identity mix curves.
        public var linear: Bool
        public var level: Bool
        public var loudness: Loudness
        public var crf: Int?
        public var audioOnly: Bool

        public init(linear: Bool = false, level: Bool = false, loudness: Loudness = .auto, crf: Int? = nil, audioOnly: Bool = false) {
            self.linear = linear
            self.level = level
            self.loudness = loudness
            self.crf = crf
            self.audioOnly = audioOnly
        }

        private enum CodingKeys: String, CodingKey {
            case linear, level, loudness, crf, audioOnly = "audio_only"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            linear = try c.decodeIfPresent(Bool.self, forKey: .linear) ?? false
            level = try c.decodeIfPresent(Bool.self, forKey: .level) ?? false
            loudness = try c.decodeIfPresent(Loudness.self, forKey: .loudness) ?? .auto
            crf = try c.decodeLenientInt(.crf)
            audioOnly = try c.decodeIfPresent(Bool.self, forKey: .audioOnly) ?? false
        }
    }

    /// `"auto"` or a LUFS target such as `-16`.
    public enum Loudness: Codable, Equatable, Sendable {
        case auto
        case lufs(Double)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let value = try? c.decode(Double.self) {
                self = .lufs(value)
            } else {
                // Any string (today only "auto") means "let the pipeline decide".
                _ = try c.decode(String.self)
                self = .auto
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .auto: try c.encode("auto")
            case .lufs(let value): try c.encode(value)
            }
        }
    }

    /// RMS of each preview stem in equal time bins (56 by default), all on the same linear scale.
    public struct Bars: Codable, Equatable, Sendable {
        public var clean: [Double]
        public var vocals: [Double]
        public var background: [Double]
        /// Present only when music was detected.
        public var music: [Double]?
        public var original: [Double]

        public init(clean: [Double], vocals: [Double], background: [Double], music: [Double]? = nil, original: [Double]) {
            self.clean = clean
            self.vocals = vocals
            self.background = background
            self.music = music
            self.original = original
        }
    }

    public init(
        protocolVersion: Int = engineProtocolVersion, input: String, name: String, duration: Double,
        hasVideo: Bool, engine: String, generative: Bool, music: Bool, sampleRate: Int = 48_000,
        outputs: Outputs, mix: Mix = .standard, settings: RenderSettings = RenderSettings(),
        previewGain: Double = 1, bars: Bars
    ) {
        self.protocolVersion = protocolVersion
        self.input = input
        self.name = name
        self.duration = duration
        self.hasVideo = hasVideo
        self.engine = engine
        self.generative = generative
        self.music = music
        self.sampleRate = sampleRate
        self.outputs = outputs
        self.mix = mix
        self.settings = settings
        self.previewGain = previewGain
        self.bars = bars
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", input, name, duration, hasVideo = "has_video", engine, generative,
             music, sampleRate = "sample_rate", outputs, mix, settings, previewGain = "preview_gain", bars
    }

    /// Lenient about everything except `outputs` and `bars`, without which the manifest is useless.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeLenientInt(.protocolVersion) ?? engineProtocolVersion
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? ""
        generative = try c.decodeIfPresent(Bool.self, forKey: .generative) ?? false
        music = try c.decodeIfPresent(Bool.self, forKey: .music) ?? false
        sampleRate = try c.decodeLenientInt(.sampleRate) ?? 48_000
        outputs = try c.decode(Outputs.self, forKey: .outputs)
        mix = try c.decodeIfPresent(Mix.self, forKey: .mix) ?? .standard
        settings = try c.decodeIfPresent(RenderSettings.self, forKey: .settings) ?? RenderSettings()
        previewGain = try c.decodeIfPresent(Double.self, forKey: .previewGain) ?? 1
        bars = try c.decode(Bars.self, forKey: .bars)
    }

    public static func decode(_ data: Data) throws -> StemsManifest {
        try JSONDecoder().decode(StemsManifest.self, from: data)
    }

    /// Reads `directory/manifest.json`.
    public static func load(from directory: URL) throws -> StemsManifest {
        try decode(Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The mix curves this job was rendered with.
    public var curve: MixCurve { MixCurve(linear: settings.linear) }
}

/// The preview stems in a stems directory.
public enum PreviewStem: String, CaseIterable, Sendable {
    case clean, vocals, background, music, original

    public var fileName: String { "preview_\(rawValue).wav" }

    public func url(in stemsDirectory: URL) -> URL {
        stemsDirectory.appendingPathComponent(fileName)
    }
}
