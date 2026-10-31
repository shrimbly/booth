import Foundation

/// Slider positions on the Done screen, each 0…100 (the CLI's `-s/-b/-m`).
public struct Mix: Codable, Hashable, Sendable {
    public static let range = 0...100
    /// The pipeline's default mix.
    public static let standard = Mix(speech: 54, background: 10, music: 10)

    public var speech: Int
    public var background: Int
    public var music: Int

    public init(speech: Int, background: Int, music: Int) {
        self.speech = Self.clamp(speech)
        self.background = Self.clamp(background)
        self.music = Self.clamp(music)
    }

    /// The same mix with every value forced into 0…100.
    public var clamped: Mix { Mix(speech: speech, background: background, music: music) }

    /// Per-stem gains for the live preview and the bar shapes (SPEC §1.4):
    /// `s_eff·clean + (1−s_eff)·vocals + b_eff·background + m_eff·music`.
    public func gains(curve: MixCurve = .standard, includeMusic: Bool = true) -> StemGains {
        let speechGain = curve.speech(Double(speech) / 100)
        return StemGains(
            clean: speechGain,
            vocals: 1 - speechGain,
            background: curve.background(Double(background) / 100),
            music: includeMusic ? curve.music(Double(music) / 100) : 0)
    }

    private static func clamp(_ value: Int) -> Int { min(range.upperBound, max(range.lowerBound, value)) }

    private enum CodingKeys: String, CodingKey { case speech, background, music }

    /// Accepts `54` or `54.0`; missing values fall back to the standard mix.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Int) throws -> Int {
            guard let real = try c.decodeIfPresent(Double.self, forKey: key), real.isFinite else { return fallback }
            return Int(real.rounded())
        }
        self.init(
            speech: try value(.speech, Self.standard.speech),
            background: try value(.background, Self.standard.background),
            music: try value(.music, Self.standard.music))
    }
}

/// Response curves from slider fraction (0…1) to stem coefficient. `--linear` jobs use identity.
public enum MixCurve: Sendable, Equatable {
    case standard
    case linear

    public init(linear: Bool) { self = linear ? .linear : .standard }

    /// `s_eff = 1 − (1 − s)^6`
    public func speech(_ s: Double) -> Double {
        let s = Self.unit(s)
        return self == .linear ? s : 1 - pow(1 - s, 6)
    }

    /// `b_eff = b²`
    public func background(_ b: Double) -> Double {
        let b = Self.unit(b)
        return self == .linear ? b : b * b
    }

    /// `m_eff = m²`
    public func music(_ m: Double) -> Double {
        let m = Self.unit(m)
        return self == .linear ? m : m * m
    }

    private static func unit(_ x: Double) -> Double { min(1, max(0, x)) }
}

/// Linear gain per preview stem. The original stem is not part of a mix: the player switches
/// to it while comparing.
public struct StemGains: Equatable, Sendable {
    public var clean: Double
    public var vocals: Double
    public var background: Double
    public var music: Double

    public init(clean: Double, vocals: Double, background: Double, music: Double) {
        self.clean = clean
        self.vocals = vocals
        self.background = background
        self.music = music
    }
}

/// The Done screen's 56-bar waveform.
public enum WaveformBars {
    public static let count = 56
    /// Bar heights in points for a normalised level: `2 + min(1, h)·20`, a compact waveform 22 pt
    /// tall at most.
    public static let minHeight = 2.0
    public static let maxExtra = 20.0

    /// The perceptual mapping's span: a bin this far below the reference draws as a dot.
    public static let rangeDB = 40.0
    /// Shapes the mapped level so quiet syllables stay short and speech fills out near the top.
    public static let exponent = 1.5
    /// The default mix's bin at this percentile maps to full height (a few louder bins clip).
    public static let referencePercentile = 0.95
    /// The reference never drops below this (about −50 dBFS), so a near-silent file is not
    /// stretched to full height. Previews are scaled to the output level (about −29 dBFS
    /// active speech), so absolute levels mean something.
    public static let referenceFloor = pow(10, -50.0 / 20)
    /// Bins quieter than this (−60 dBFS) are silence: always a dot.
    public static let silenceFloor = pow(10, -60.0 / 20)

    /// Normalised level per bar for the current mix: `h = √(voice² + (b_eff·bg)² + (m_eff·music)²)`
    /// with `voice = s_eff·clean + (1−s_eff)·vocals`, so the sliders reshape the bars. While
    /// comparing, the original's bins are shown on the same scale.
    ///
    /// - Linear (the default, used for the synthetic demo bars): divided by the peak of the
    ///   default mix, so the default mix just fills the height.
    /// - `perceptual` (real manifests): in dB against the `referencePercentile` bin of the
    ///   default mix (at least `referenceFloor`), `clamp((dB + rangeDB) / rangeDB)^exponent`,
    ///   and 0 below `silenceFloor`. Speech then reads as dense bars and pauses as dots.
    public static func levels(
        bars: StemsManifest.Bars, mix: Mix, curve: MixCurve = .standard,
        includeMusic: Bool, comparing: Bool, count: Int = count, perceptual: Bool = false
    ) -> [Double] {
        let clean = resample(bars.clean, to: count)
        let vocals = resample(bars.vocals, to: count)
        let background = resample(bars.background, to: count)
        let music = includeMusic ? resample(bars.music ?? [], to: count) : Array(repeating: 0, count: count)

        func mixed(_ gains: StemGains) -> [Double] {
            (0..<count).map { i in
                let voice = gains.clean * clean[i] + gains.vocals * vocals[i]
                let bg = gains.background * background[i]
                let mu = gains.music * music[i]
                return (voice * voice + bg * bg + mu * mu).squareRoot()
            }
        }

        let standard = mixed(Mix.standard.gains(curve: curve, includeMusic: includeMusic))
        let raw = comparing ? resample(bars.original, to: count) : mixed(mix.gains(curve: curve, includeMusic: includeMusic))
        if perceptual {
            let reference = max(referenceFloor, percentile(standard, referencePercentile))
            return raw.map { perceptualLevel($0, reference: reference) }
        }
        let peak = standard.max() ?? 0
        guard peak > 0 else { return Array(repeating: 0, count: count) }
        return raw.map { $0 / peak }
    }

    /// One bin's perceptual level against `reference` (see `levels`).
    public static func perceptualLevel(_ h: Double, reference: Double) -> Double {
        guard h > 0, h >= silenceFloor, reference > 0 else { return 0 }
        let db = 20 * log10(h / reference)
        return pow(min(1, max(0, (db + rangeDB) / rangeDB)), exponent)
    }

    /// The value at `fraction` of the sorted values (nearest rank), so it is one of the bins.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * min(1, max(0, fraction))).rounded())
        return sorted[index]
    }

    /// Bar height in points for a normalised level.
    public static func height(forLevel level: Double) -> Double {
        minHeight + min(1, max(0, level)) * maxExtra
    }

    /// Fits `values` into `count` bins, taking each bin's loudest source value. Missing data → 0.
    static func resample(_ values: [Double], to count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        if values.count == count { return values }
        return (0..<count).map { i in
            let lower = i * values.count / count
            let upper = max(lower + 1, (i + 1) * values.count / count)
            return values[lower..<min(upper, values.count)].max() ?? 0
        }
    }
}

extension StemsManifest.Bars {
    /// A plausible speech shape for jobs without a manifest (demo mode, snapshots). Ported from
    /// the prototype's `envAt` / `noiseAt` / `musicAt` so the bars react to the sliders the same way.
    public static func synthetic(music: Bool, count: Int = WaveformBars.count) -> Self {
        func envelope(_ i: Int) -> Double {
            let x = Double(i) / Double(count)
            let words = abs(sin(x * 23.0) * sin(x * 7.3 + 1.1))
            let pause = sin(x * 4.1 + 0.6) > -0.55 ? 1.0 : 0.06
            return min(1, words * 1.25 * pause)
        }
        func noise(_ i: Int) -> Double {
            let v = sin(Double(i) * 12.9898) * 43758.5453
            return 0.12 + (v - v.rounded(.down)) * 0.16
        }
        func accompaniment(_ i: Int) -> Double { 0.16 + 0.1 * sin(Double(i) * 0.9) }

        let indices = 0..<count
        return Self(
            clean: indices.map(envelope),
            vocals: indices.map { 0.78 * envelope($0) + 1.4 * noise($0) },
            background: indices.map { 3.2 * noise($0) },
            music: music ? indices.map { 2.6 * accompaniment($0) } : nil,
            original: indices.map { 0.72 * envelope($0) + 1.4 * noise($0) + (music ? 0.9 * accompaniment($0) : 0) })
    }
}
