import Foundation

/// The active speech level of the preview's voice at any Speech setting, from one pass over the
/// clean and vocals preview stems (SPEC §1.4, §1.5).
///
/// Save (`booth remix`) re-applies auto gain from the active speech level of the NEW voice,
/// `s·clean + (1−s)·vocals`, while the preview stems carry the fixed gain G0 of the mix the job
/// was enhanced at. The preview multiplies its enhanced stems by `correction` so it sounds as
/// loud as the file Save writes, including auto gain's no-speech floor and boost cap. Remix's
/// peak guard (scale down when a sample would pass 0.99) is not modelled; it only matters for
/// mixes that clip.
///
/// The level mirrors `dsp.active_speech_db` exactly: 50 ms frames, RMS per whole frame, dBFS,
/// then the mean of the frames at or above the 0.60 quantile (numpy's linear interpolation).
/// A frame's energy at any `s` follows from three sums, so the stems are read only once:
/// `E = s²·cc + 2s(1−s)·cv + (1−s)²·vv`.
public struct SpeechLevel: Equatable, Sendable {
    public static let frameSeconds = 0.05
    public static let quantile = 0.60

    // Auto gain, mirroring SPEECH_ACTIVE_TARGET_DB, SPEECH_FLOOR_DB and MAX_AUTO_GAIN_DB in
    // src/booth/pipeline.py: keep them in step.
    /// The active speech level auto gain aims for (dBFS).
    public static let targetDB = -29.0
    /// A voice quieter than this (dBFS) holds no speech: auto gain leaves it at 1.
    public static let floorDB = -70.0
    /// The most auto gain boosts a voice (dB).
    public static let maxGainDB = 30.0

    /// Samples per frame (`int(sr · 0.05)`, 2 400 at 48 kHz).
    public let frameLength: Int
    /// Per whole frame: Σclean², Σvocals², Σclean·vocals.
    public private(set) var cc: [Double] = []
    public private(set) var vv: [Double] = []
    public private(set) var cv: [Double] = []

    // The frame being filled.
    private var filled = 0
    private var partialCC = 0.0, partialVV = 0.0, partialCV = 0.0

    public init(sampleRate: Double) {
        frameLength = max(1, Int(sampleRate * Self.frameSeconds))
    }

    /// From whole signals (tests, short clips). Extra samples of the longer one are ignored.
    public init(clean: [Float], vocals: [Float], sampleRate: Double) {
        self.init(sampleRate: sampleRate)
        for i in 0..<min(clean.count, vocals.count) { add(clean: clean[i], vocals: vocals[i]) }
    }

    public var frameCount: Int { cc.count }

    /// Feeds the next sample of each stem. A trailing partial frame never counts, like numpy's
    /// `x[:k * n]`.
    public mutating func add(clean: Float, vocals: Float) {
        let c = Double(clean), v = Double(vocals)
        partialCC += c * c
        partialVV += v * v
        partialCV += c * v
        filled += 1
        if filled == frameLength {
            cc.append(partialCC)
            vv.append(partialVV)
            cv.append(partialCV)
            partialCC = 0
            partialVV = 0
            partialCV = 0
            filled = 0
        }
    }

    /// `dsp.active_speech_db(s·clean + (1−s)·vocals)`; nil without a whole frame.
    public func activeSpeechDB(speechGain s: Double) -> Double? {
        guard !cc.isEmpty else { return nil }
        let n = Double(frameLength)
        let a = s * s, b = 2 * s * (1 - s), c = (1 - s) * (1 - s)
        var db = [Double](repeating: 0, count: cc.count)
        for k in cc.indices {
            let energy = max(0, a * cc[k] + b * cv[k] + c * vv[k])
            db[k] = 20 * log10((energy / n).squareRoot() + 1e-12)
        }
        let threshold = Self.numpyQuantile(db.sorted(), Self.quantile)
        var sum = 0.0
        var count = 0
        for value in db where value >= threshold {
            sum += value
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// The gain that takes the preview (scaled for `referenceSpeechGain`) to what remix writes at
    /// `speechGain`. 1 when either level is unknown.
    public func correction(referenceSpeechGain reference: Double, speechGain s: Double, previewGain: Double = 1) -> Double {
        guard let referenceDB = activeSpeechDB(speechGain: reference), let currentDB = activeSpeechDB(speechGain: s) else {
            return 1
        }
        return Self.correction(referenceDB: referenceDB, currentDB: currentDB, previewGain: previewGain)
    }

    /// The change in auto gain from the reference voice to the current one. Both levels come from
    /// the preview stems, which `previewGain` (G0) made louder than the voice remix measures.
    /// Without the floor or the cap in play this is `10^((level(ref) − level(s)) / 20)`.
    public static func correction(referenceDB: Double, currentDB: Double, previewGain: Double) -> Double {
        let previewDB = previewGain.isFinite && previewGain > 0 ? 20 * log10(previewGain) : 0
        let changeDB = autoGainDB(voiceDB: currentDB - previewDB) - autoGainDB(voiceDB: referenceDB - previewDB)
        let factor = pow(10, changeDB / 20)
        return factor.isFinite && factor > 0 ? factor : 1
    }

    /// `pipeline.write_mix`'s auto gain (dB) for a voice at `voiceDB` active speech, before its peak
    /// guard: none below the no-speech floor, else up to the target, boosting by at most `maxGainDB`.
    public static func autoGainDB(voiceDB: Double) -> Double {
        voiceDB < floorDB ? 0 : min(targetDB - voiceDB, maxGainDB)
    }

    /// `np.quantile(a, q)` with the default linear method, on sorted values, including numpy's
    /// two-sided lerp so threshold ties land on the same side.
    static func numpyQuantile(_ sorted: [Double], _ q: Double) -> Double {
        guard let last = sorted.indices.last else { return .nan }
        let position = q * Double(last)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, last)
        let t = position - Double(lower)
        let a = sorted[lower], b = sorted[upper]
        let difference = b - a
        return t >= 0.5 ? b - difference * (1 - t) : a + difference * t
    }
}
