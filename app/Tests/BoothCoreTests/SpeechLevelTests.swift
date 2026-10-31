import Foundation
import Testing
@testable import BoothCore

@Suite("Speech level")
struct SpeechLevelTests {
    /// 10 whole 50 ms frames at 48 kHz plus 1 000 samples that must be ignored; frame
    /// amplitudes vary so the 0.60 quantile matters.
    static func signal() -> (clean: [Float], vocals: [Float]) {
        let amps = [0.5, 0.01, 0.3, 0.001, 0.8, 0.05, 0.2, 0.0, 0.6, 0.02]
        var clean: [Float] = []
        var vocals: [Float] = []
        for i in 0..<25_000 {
            let amp = amps[min(i / 2400, 10) % 10]
            let c = Float(amp * sin(2 * Double.pi * 200 * Double(i) / 48_000))
            clean.append(c)
            vocals.append(Float(0.5 * Double(c) + 0.1 * sin(2 * Double.pi * 50 * Double(i) / 48_000 + 0.3)))
        }
        return (clean, vocals)
    }

    /// Expected values from `dsp.active_speech_db(s·clean + (1−s)·vocals)` on the same signal in
    /// float32, computed with the repo's numpy by scratchpad/booth/tmp/fix-core/scripts/
    /// speechlevel_ref.py.
    @Test(arguments: [
        (0.0, -13.945575981629055),
        (0.5, -11.106855176610267),
        (0.990525703104, -8.764520285175628),
        (1.0, -8.723637497996272),
        (0.7378559999999998, -9.91403835519758),
    ])
    func matchesNumpy(speechGain: Double, expectedDB: Double) throws {
        let (clean, vocals) = Self.signal()
        let level = SpeechLevel(clean: clean, vocals: vocals, sampleRate: 48_000)
        #expect(level.frameLength == 2400)
        #expect(level.frameCount == 10)
        let db = try #require(level.activeSpeechDB(speechGain: speechGain))
        #expect(abs(db - expectedDB) < 1e-5)
    }

    @Test func correctionIsOneAtTheReferenceMix() {
        let (clean, vocals) = Self.signal()
        let level = SpeechLevel(clean: clean, vocals: vocals, sampleRate: 48_000)
        let standard = Mix.standard.gains().clean
        #expect(level.correction(referenceSpeechGain: standard, speechGain: standard) == 1)
        // Speech 0 is quieter here, so remix raises it: the preview must too.
        let factor = level.correction(referenceSpeechGain: standard, speechGain: 0)
        #expect(abs(20 * log10(factor) - (-8.764520285175628 + 13.945575981629055)) < 1e-5)
    }

    @Test func withoutAWholeFrameThereIsNoCorrection() {
        let level = SpeechLevel(clean: [0.5, 0.5], vocals: [0.1, 0.1], sampleRate: 48_000)
        #expect(level.frameCount == 0)
        #expect(level.activeSpeechDB(speechGain: 1) == nil)
        #expect(level.correction(referenceSpeechGain: 0.99, speechGain: 0) == 1)
    }

    @Test func silenceGivesNoFactorChange() {
        let zeros = [Float](repeating: 0, count: 4800)
        let level = SpeechLevel(clean: zeros, vocals: zeros, sampleRate: 48_000)
        #expect(level.correction(referenceSpeechGain: 0.99, speechGain: 0.2) == 1)
    }

    @Test func autoGainHasAFloorAndACap() {
        #expect(SpeechLevel.autoGainDB(voiceDB: -40) == 11)
        #expect(SpeechLevel.autoGainDB(voiceDB: -10) == -19)
        // Boosts stop at +30 dB; below −70 dBFS there is no speech to raise.
        #expect(SpeechLevel.autoGainDB(voiceDB: -65) == 30)
        #expect(SpeechLevel.autoGainDB(voiceDB: -70) == 30)
        #expect(SpeechLevel.autoGainDB(voiceDB: -70.5) == 0)
        #expect(SpeechLevel.autoGainDB(voiceDB: -240) == 0)
    }

    /// The preview stems carry G0, so a level measured on them is `previewGain` above what remix
    /// measures on the voice it re-gains.
    @Test func correctionFollowsTheFloorAndTheCap() {
        func db(_ factor: Double) -> Double { 20 * log10(factor) }
        func gain(_ db: Double) -> Double { pow(10, db / 20) }
        // Away from the limits it is just the level difference, whatever G0 is.
        #expect(abs(db(SpeechLevel.correction(referenceDB: -20, currentDB: -26, previewGain: 1)) - 6) < 1e-9)
        #expect(abs(db(SpeechLevel.correction(referenceDB: -29, currentDB: -35, previewGain: gain(9))) - 6) < 1e-9)
        // A voice at −65 dBFS was raised by the +30 dB cap. At −62 dBFS Save still raises it by
        // 30 dB, so the preview must not drop by 3 dB.
        #expect(abs(db(SpeechLevel.correction(referenceDB: -35, currentDB: -32, previewGain: gain(30))) - 0) < 1e-9)
        // No speech at −75 dBFS, so G0 was 1. A −68 dBFS voice gets the full +30 dB from Save.
        #expect(abs(db(SpeechLevel.correction(referenceDB: -75, currentDB: -68, previewGain: 1)) - 30) < 1e-9)
        #expect(SpeechLevel.correction(referenceDB: -75, currentDB: -80, previewGain: 1) == 1)
        // A missing or broken G0 counts as 1.
        #expect(SpeechLevel.correction(referenceDB: -75, currentDB: -80, previewGain: 0) == 1)
    }

    @Test func numpyQuantileInterpolates() {
        #expect(abs(SpeechLevel.numpyQuantile([1, 2, 3, 4, 5], 0.6) - 3.4) < 1e-12)
        #expect(SpeechLevel.numpyQuantile([7], 0.6) == 7)
        #expect(SpeechLevel.numpyQuantile([0, 10], 0.6) == 6)
    }

    @Test func frameLengthFollowsTheSampleRate() {
        #expect(SpeechLevel(sampleRate: 44_100).frameLength == 2205)
        #expect(SpeechLevel(sampleRate: 48_000).frameLength == 2400)
    }
}
