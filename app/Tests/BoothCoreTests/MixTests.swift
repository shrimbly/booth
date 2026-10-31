import Foundation
import Testing
@testable import BoothCore

@Suite("Mix and waveform")
struct MixTests {
    @Test func standardCurves() {
        let curve = MixCurve.standard
        #expect(curve.speech(0) == 0)
        #expect(curve.speech(1) == 1)
        #expect(abs(curve.speech(0.54) - 0.990525703104) < 1e-9)
        #expect(abs(curve.background(0.1) - 0.01) < 1e-12)
        #expect(curve.music(0.5) == 0.25)
        #expect(curve.speech(2) == 1)
        #expect(curve.background(-1) == 0)
    }

    @Test func linearCurvesAreIdentity() {
        let curve = MixCurve(linear: true)
        #expect(curve == .linear)
        #expect(curve.speech(0.54) == 0.54)
        #expect(curve.background(0.1) == 0.1)
        #expect(curve.music(0.3) == 0.3)
    }

    @Test func gains() {
        let gains = Mix.standard.gains()
        #expect(abs(gains.clean - 0.990525703104) < 1e-9)
        #expect(abs(gains.clean + gains.vocals - 1) < 1e-12)
        #expect(abs(gains.background - 0.01) < 1e-12)
        #expect(abs(gains.music - 0.01) < 1e-12)
        #expect(Mix.standard.gains(includeMusic: false).music == 0)
        #expect(Mix(speech: 100, background: 50, music: 100).gains(curve: .linear) == StemGains(clean: 1, vocals: 0, background: 0.5, music: 1))
    }

    @Test func valuesAreClamped() {
        let mix = Mix(speech: 140, background: -5, music: 50)
        #expect(mix == Mix(speech: 100, background: 0, music: 50))
        var raw = Mix.standard
        raw.speech = 300
        #expect(raw.clamped.speech == 100)
    }

    @Test func decodesIntegersAndReals() throws {
        let mix = try JSONDecoder().decode(Mix.self, from: Data(#"{"speech":54.0,"background":9.6,"music":10}"#.utf8))
        #expect(mix == Mix(speech: 54, background: 10, music: 10))
        let partial = try JSONDecoder().decode(Mix.self, from: Data(#"{"speech":70}"#.utf8))
        #expect(partial == Mix(speech: 70, background: 10, music: 10))
        let encoded = String(decoding: try JSONEncoder().encode(Mix.standard), as: UTF8.self)
        #expect(encoded.contains(#""speech":54"#))
    }

    @Test func defaultMixFillsTheHeight() {
        let bars = StemsManifest.Bars.synthetic(music: true)
        let levels = WaveformBars.levels(bars: bars, mix: .standard, includeMusic: true, comparing: false)
        #expect(levels.count == 56)
        #expect(abs((levels.max() ?? 0) - 1) < 1e-12)
        #expect(levels.allSatisfy { $0 >= 0 })
    }

    @Test func levelsFollowTheFormula() {
        let bars = StemsManifest.Bars(
            clean: [1, 0.5], vocals: [0.5, 1], background: [1, 1], music: [2, 0], original: [3, 1])
        let mix = Mix(speech: 100, background: 100, music: 50)
        let levels = WaveformBars.levels(bars: bars, mix: mix, curve: .linear, includeMusic: true, comparing: false, count: 2)
        // Default-mix peak under linear curves: s=.54, b=.1, m=.1.
        func h(_ s: Double, _ b: Double, _ m: Double, _ i: Int) -> Double {
            let voice = s * bars.clean[i] + (1 - s) * bars.vocals[i]
            return (voice * voice + pow(b * bars.background[i], 2) + pow(m * bars.music![i], 2)).squareRoot()
        }
        let peak = max(h(0.54, 0.1, 0.1, 0), h(0.54, 0.1, 0.1, 1))
        #expect(abs(levels[0] - h(1, 1, 0.5, 0) / peak) < 1e-12)
        #expect(abs(levels[1] - h(1, 1, 0.5, 1) / peak) < 1e-12)

        let comparing = WaveformBars.levels(bars: bars, mix: mix, curve: .linear, includeMusic: true, comparing: true, count: 2)
        #expect(abs(comparing[0] - 3 / peak) < 1e-12)
        #expect(abs(comparing[1] - 1 / peak) < 1e-12)
    }

    @Test func raisingBackgroundRaisesQuietBars() {
        let bars = StemsManifest.Bars.synthetic(music: false)
        let standard = WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false)
        let louder = WaveformBars.levels(bars: bars, mix: Mix(speech: 54, background: 80, music: 10), includeMusic: false, comparing: false)
        #expect(zip(standard, louder).allSatisfy { $1 >= $0 })
        #expect(zip(standard, louder).contains { $1 > $0 + 0.1 })
    }

    @Test func musicIsIgnoredWithoutMusic() {
        let bars = StemsManifest.Bars.synthetic(music: true)
        let a = WaveformBars.levels(bars: bars, mix: Mix(speech: 54, background: 10, music: 0), includeMusic: false, comparing: false)
        let b = WaveformBars.levels(bars: bars, mix: Mix(speech: 54, background: 10, music: 100), includeMusic: false, comparing: false)
        #expect(a == b)
    }

    @Test func silentStemsGiveFlatBars() {
        let zeros = Array(repeating: 0.0, count: 56)
        let bars = StemsManifest.Bars(clean: zeros, vocals: zeros, background: zeros, original: zeros)
        #expect(WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false) == zeros)
    }

    // MARK: Perceptual mapping (real manifests)

    static func dBFS(_ db: Double) -> Double { pow(10, db / 20) }

    /// Speech-like bars: words around −27 dBFS with real pauses at −70 dBFS.
    static func speechBars() -> StemsManifest.Bars {
        let clean = (0..<56).map { i -> Double in (i / 7) % 3 == 2 ? dBFS(-70) : dBFS(-27 - Double(i % 4)) }
        return StemsManifest.Bars(
            clean: clean, vocals: clean.map { $0 * 1.1 }, background: clean.map { _ in dBFS(-45) },
            original: clean.map { $0 * 0.8 + dBFS(-40) })
    }

    @Test func perceptualSilenceDrawsDots() {
        let zeros = Array(repeating: 0.0, count: 56)
        let bars = StemsManifest.Bars(clean: zeros, vocals: zeros, background: zeros, original: zeros)
        let levels = WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false, perceptual: true)
        #expect(levels == zeros)
        #expect(levels.allSatisfy { WaveformBars.height(forLevel: $0) == WaveformBars.minHeight })
    }

    @Test func perceptualPausesAreDotsAndSpeechIsTall() {
        let bars = Self.speechBars()
        let levels = WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false, perceptual: true)
        for (i, level) in levels.enumerated() {
            if (i / 7) % 3 == 2 {
                #expect(level == 0, "pause bin \(i)")
            } else {
                #expect(level > 0.85, "speech bin \(i)")
            }
        }
    }

    @Test func perceptualIsMonotonicInLevel() {
        let reference = Self.dBFS(-27)
        let hs = stride(from: -90.0, through: 0, by: 0.5).map(Self.dBFS)
        let levels = hs.map { WaveformBars.perceptualLevel($0, reference: reference) }
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(levels.first == 0 && levels.last == 1)
        #expect(WaveformBars.perceptualLevel(Self.dBFS(-61), reference: reference) == 0) // below the silence floor
        #expect(WaveformBars.perceptualLevel(0, reference: reference) == 0)
        #expect(abs(WaveformBars.perceptualLevel(Self.dBFS(-47), reference: reference) - pow(0.5, 1.5)) < 1e-12)
    }

    @Test func perceptualBackgroundRaisesQuietBins() {
        let bars = Self.speechBars()
        let standard = WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false, perceptual: true)
        let louder = WaveformBars.levels(bars: bars, mix: Mix(speech: 54, background: 100, music: 10), includeMusic: false, comparing: false, perceptual: true)
        #expect(zip(standard, louder).allSatisfy { $1 >= $0 })
        let pauses = (0..<56).filter { ($0 / 7) % 3 == 2 }
        #expect(pauses.allSatisfy { louder[$0] > standard[$0] + 0.1 }) // −45 dBFS room tone shows
    }

    @Test func perceptualReferenceIsTheDefaultMixsP95Bin() throws {
        let bars = StemsManifest.Bars.synthetic(music: true)
        // Scale to output-like levels (about −20 dBFS peaks) so the floor doesn't decide.
        func scaled(_ v: [Double]) -> [Double] { v.map { $0 * 0.1 } }
        let real = StemsManifest.Bars(
            clean: scaled(bars.clean), vocals: scaled(bars.vocals), background: scaled(bars.background),
            music: bars.music.map(scaled), original: scaled(bars.original))
        let standardGains = Mix.standard.gains()
        let h = (0..<56).map { i -> Double in
            let voice = standardGains.clean * real.clean[i] + standardGains.vocals * real.vocals[i]
            return (voice * voice + pow(standardGains.background * real.background[i], 2) + pow(standardGains.music * real.music![i], 2)).squareRoot()
        }
        let p95 = h.sorted()[Int((55 * 0.95).rounded())]
        let levels = WaveformBars.levels(bars: real, mix: .standard, includeMusic: true, comparing: false, perceptual: true)
        let index = try #require(h.firstIndex(of: p95))
        #expect(abs(levels[index] - 1) < 1e-12)
        #expect(levels.filter { $0 >= 1 - 1e-12 }.count == h.filter { $0 >= p95 }.count)
        // Comparing maps the original's bins against the same reference.
        let comparing = WaveformBars.levels(bars: real, mix: .standard, includeMusic: true, comparing: true, perceptual: true)
        #expect(abs(comparing[3] - WaveformBars.perceptualLevel(real.original[3], reference: p95)) < 1e-12)
    }

    @Test func perceptualReferenceIsFloored() {
        // A whisper-quiet file (−65 dBFS speech) is not stretched to full height.
        let quiet = (0..<56).map { _ in Self.dBFS(-58) }
        let bars = StemsManifest.Bars(clean: quiet, vocals: quiet, background: quiet, original: quiet)
        let levels = WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false, perceptual: true)
        #expect(levels.allSatisfy { abs($0 - pow(32.0 / 40, 1.5)) < 1e-3 }) // −58 against the −50 floor
    }

    @Test func linearStaysTheDefault() {
        let bars = StemsManifest.Bars.synthetic(music: false)
        #expect(WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false)
            == WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false, perceptual: false))
        #expect(WaveformBars.rangeDB == 40 && WaveformBars.exponent == 1.5 && WaveformBars.referencePercentile == 0.95)
    }

    @Test func resamplesToTheBarCount() {
        #expect(WaveformBars.resample([1, 5, 2, 8], to: 2) == [5, 8])
        #expect(WaveformBars.resample([1, 2], to: 4) == [1, 1, 2, 2])
        #expect(WaveformBars.resample([], to: 3) == [0, 0, 0])
        let bars = StemsManifest.Bars(clean: Array(repeating: 1, count: 112), vocals: [], background: [], original: [])
        #expect(WaveformBars.levels(bars: bars, mix: .standard, includeMusic: false, comparing: false).count == 56)
    }

    @Test func barHeights() {
        #expect(WaveformBars.height(forLevel: 0) == 2)
        #expect(WaveformBars.height(forLevel: 0.5) == 12)
        #expect(WaveformBars.height(forLevel: 1) == 22)
        #expect(WaveformBars.height(forLevel: 3) == 22)
        #expect(WaveformBars.height(forLevel: -1) == 2)
    }

    @Test func syntheticBars() {
        let withMusic = StemsManifest.Bars.synthetic(music: true)
        #expect(withMusic.clean.count == 56)
        #expect(withMusic.music?.count == 56)
        #expect(StemsManifest.Bars.synthetic(music: false).music == nil)
        #expect(withMusic.clean.allSatisfy { (0...1).contains($0) })
    }
}
