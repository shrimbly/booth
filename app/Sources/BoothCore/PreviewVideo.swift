import Foundation

/// The picture a finished video job shows on its Done screen. The video plays muted; the sound
/// is always the preview stems, so the sliders and ⌥ keep working.
public struct PreviewVideo: Equatable, Sendable {
    public var url: URL
    /// Display width ÷ height, after rotation and pixel aspect.
    public var aspect: Double
    /// When the audio starts on the video's timeline, in seconds. The preview stems begin at the
    /// first audio sample, so preview time 0 is this far into the video.
    public var audioStart: Double
    /// The preview's length in seconds.
    public var duration: Double

    public init(url: URL, aspect: Double, audioStart: Double = 0, duration: Double) {
        self.url = url
        self.aspect = aspect
        self.audioStart = audioStart
        self.duration = duration
    }

    /// The file to show for `result`: its output video while that is on disk, else the input
    /// when the engine saw video in it. Needs the manifest, which gives the preview's length.
    public static func source(for result: JobResult, fileExists: (URL) -> Bool) -> URL? {
        guard let manifest = result.manifest, manifest.duration > 0 else { return nil }
        if let video = result.video ?? manifest.outputs.video.map({ URL(fileURLWithPath: $0) }), fileExists(video) {
            return video
        }
        guard manifest.hasVideo, !manifest.input.isEmpty else { return nil }
        let input = URL(fileURLWithPath: manifest.input)
        return fileExists(input) ? input : nil
    }

    /// The video time for a preview playhead (0…1).
    public func time(atPlayhead playhead: Double) -> Double {
        audioStart + min(1, max(0, playhead)) * duration
    }
}

/// Keeping the muted video on the preview's clock, and sizing it.
public enum VideoSync {
    /// While playing, the video runs on its own clock and is only re-seeked once it drifts this
    /// far (seconds) from the audio.
    public static let playingTolerance = 0.08
    /// While paused, any difference beyond this (seconds; under a frame at 60 fps) re-seeks,
    /// so scrubbing the waveform moves the picture.
    public static let pausedTolerance = 0.01
    /// The tallest the video gets (points).
    public static let maxHeight = 200.0
    /// A wider-than-tall default until the file says otherwise.
    public static let fallbackAspect = 16.0 / 9.0

    public static func needsSeek(current: Double, expected: Double, isPlaying: Bool) -> Bool {
        guard current.isFinite else { return true }
        return abs(current - expected) > (isPlaying ? playingTolerance : pausedTolerance)
    }

    /// Display aspect of a track `width` × `height` pixels, turned a quarter (portrait phone
    /// video) or not, with non-square pixels widened by `pixelAspect`.
    public static func displayAspect(width: Double, height: Double, quarterTurn: Bool, pixelAspect: Double = 1) -> Double {
        let w = width * (pixelAspect > 0 ? pixelAspect : 1)
        let aspect = quarterTurn ? height / w : w / height
        return aspect.isFinite && aspect > 0 ? aspect : fallbackAspect
    }

    /// The video's box: the full `width`, as tall as the aspect asks up to `maxHeight`. A taller
    /// video is pillarboxed inside it.
    public static func height(aspect: Double, width: Double, maxHeight: Double = maxHeight) -> Double {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : fallbackAspect
        return min(maxHeight, (width / aspect).rounded())
    }
}
