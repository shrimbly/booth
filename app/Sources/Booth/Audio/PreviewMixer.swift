import BoothCore
import Foundation
import os

/// The render-thread half of the preview player: mixes the memory-mapped preview stems sample
/// by sample, so every stem stays sample-locked by construction.
///
/// The main thread writes `Controls` under a lock; the render callback only ever *tries* that
/// lock and keeps its last copy when the main thread holds it, so it never waits. Gains glide to
/// their targets over ~30 ms (slider moves, A/B switches) and the master level fades over 5 ms
/// around play, pause and seek, so nothing clicks.
final class PreviewMixer: @unchecked Sendable {
    /// Per-stem linear gains; `original` is the A/B reference.
    struct Gains: Equatable, Sendable {
        var clean: Float = 0
        var vocals: Float = 0
        var background: Float = 0
        var music: Float = 0
        var original: Float = 0

        /// The enhanced mix, or the original alone while comparing. `enhancedScale` multiplies
        /// every enhanced stem (the Speech loudness correction, see `SpeechLevel`), never the
        /// original, which is already matched to the output level.
        init(_ gains: StemGains, comparing: Bool, enhancedScale: Double = 1) {
            if comparing {
                original = 1
            } else {
                clean = Float(gains.clean * enhancedScale)
                vocals = Float(gains.vocals * enhancedScale)
                background = Float(gains.background * enhancedScale)
                music = Float(gains.music * enhancedScale)
            }
        }

        /// The largest gain; the glide speeds up past 1 so it still takes ~30 ms.
        var largest: Float { max(clean, vocals, background, music, original) }
    }

    struct Controls: Sendable {
        var targets: Gains
        var isPlaying = false
        /// Bumped by every seek; the render thread applies `seekFrame` once per generation.
        var seekGeneration = 0
        var seekFrame = 0
    }

    struct Report: Sendable, Equatable {
        var frame = 0
        var appliedSeekGeneration = 0
        var reachedEnd = false
    }

    static let gainGlideSeconds = 0.030
    static let masterFadeSeconds = 0.005

    let sampleRate: Double
    let frameCount: Int
    private let clean, vocals, background, music, original: MappedStem?

    private let controls: OSAllocatedUnfairLock<Controls>
    private let report = OSAllocatedUnfairLock(initialState: Report())

    // Render thread only.
    private var renderControls: Controls
    private var current: Gains
    private var master: Float = 0
    private var frame = 0
    private var appliedSeekGeneration = 0
    private var reachedEnd = false
    private let gainStep: Float
    private let masterStep: Float

    /// `stems` by role; missing roles are silent. With no stems at all the mixer plays
    /// `fallbackDuration` seconds of silence, so the Done screen still works.
    init(stems: [PreviewStem: MappedStem], sampleRate: Double, fallbackDuration: Double, targets: Gains) {
        clean = stems[.clean]
        vocals = stems[.vocals]
        background = stems[.background]
        music = stems[.music]
        original = stems[.original]
        self.sampleRate = sampleRate
        let lengths = stems.values.map(\.frameCount)
        frameCount = lengths.min() ?? max(1, Int(fallbackDuration * sampleRate))
        let initial = Controls(targets: targets)
        controls = OSAllocatedUnfairLock(initialState: initial)
        renderControls = initial
        current = targets
        gainStep = Float(1 / (Self.gainGlideSeconds * sampleRate))
        masterStep = Float(1 / (Self.masterFadeSeconds * sampleRate))
    }

    // MARK: - Main thread

    func setTargets(_ targets: Gains) {
        controls.withLock { $0.targets = targets }
    }

    func setPlaying(_ playing: Bool) {
        controls.withLock { $0.isPlaying = playing }
    }

    /// Jumps to `frame` (clamped). Audible playback fades out, jumps, and fades back in.
    func seek(toFrame target: Int) {
        let clamped = min(max(0, target), frameCount - 1)
        controls.withLock {
            $0.seekGeneration += 1
            $0.seekFrame = clamped
        }
    }

    /// Where playback is, counting a seek the render thread has not applied yet.
    struct Position: Equatable {
        var frame: Int
        /// The end was reached and no seek is pending since.
        var reachedEnd: Bool
    }

    func position() -> Position {
        let requested = controls.withLock { $0 }
        let rendered = report.withLock { $0 }
        if rendered.appliedSeekGeneration != requested.seekGeneration {
            return Position(frame: requested.seekFrame, reachedEnd: false)
        }
        return Position(frame: rendered.frame, reachedEnd: rendered.reachedEnd)
    }

    // MARK: - Render thread

    /// Fills `output` with `count` mono samples.
    func render(into output: UnsafeMutablePointer<Float>, count: Int) {
        if let latest = controls.withLockIfAvailable({ $0 }) { renderControls = latest }
        let targets = renderControls.targets
        var seekPending = renderControls.seekGeneration != appliedSeekGeneration
        // Gains above 1 (the Speech loudness correction) glide proportionally faster, so every
        // change still lands within the ~30 ms glide.
        let gainStep = self.gainStep * max(1, targets.largest, current.largest)

        for index in 0..<count {
            let audible = renderControls.isPlaying && !seekPending && !reachedEnd
            let masterTarget: Float = audible ? 1 : 0
            master = Self.step(master, toward: masterTarget, by: masterStep)

            if master == 0 && masterTarget == 0 {
                if seekPending {
                    frame = renderControls.seekFrame
                    appliedSeekGeneration = renderControls.seekGeneration
                    reachedEnd = false
                    seekPending = false
                }
                output[index] = 0
                continue
            }
            guard frame < frameCount else {
                reachedEnd = true
                output[index] = 0
                continue
            }

            current.clean = Self.step(current.clean, toward: targets.clean, by: gainStep)
            current.vocals = Self.step(current.vocals, toward: targets.vocals, by: gainStep)
            current.background = Self.step(current.background, toward: targets.background, by: gainStep)
            current.music = Self.step(current.music, toward: targets.music, by: gainStep)
            current.original = Self.step(current.original, toward: targets.original, by: gainStep)

            var mixed: Float = 0
            if let clean, current.clean != 0 { mixed += current.clean * clean.sample(frame) }
            if let vocals, current.vocals != 0 { mixed += current.vocals * vocals.sample(frame) }
            if let background, current.background != 0 { mixed += current.background * background.sample(frame) }
            if let music, current.music != 0 { mixed += current.music * music.sample(frame) }
            if let original, current.original != 0 { mixed += current.original * original.sample(frame) }
            output[index] = master * mixed
            frame += 1
        }

        let snapshot = Report(frame: frame, appliedSeekGeneration: appliedSeekGeneration, reachedEnd: reachedEnd)
        _ = report.withLockIfAvailable { $0 = snapshot }
    }

    @inline(__always)
    private static func step(_ value: Float, toward target: Float, by amount: Float) -> Float {
        if value < target { return min(target, value + amount) }
        if value > target { return max(target, value - amount) }
        return value
    }
}
