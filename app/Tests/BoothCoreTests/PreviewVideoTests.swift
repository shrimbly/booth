import Foundation
import Testing
@testable import BoothCore

@Suite("Preview video")
struct PreviewVideoTests {
    private let folder = URL(fileURLWithPath: "/tmp/booth-video", isDirectory: true)

    private func result(video: URL?, input: String, hasVideo: Bool, duration: Double = 12, manifest: Bool = true) -> JobResult {
        let outputs = StemsManifest.Outputs(wav: folder.appendingPathComponent("clip-enhanced.wav").path, video: video?.path)
        let stems = StemsManifest(
            input: input, name: "clip", duration: duration, hasVideo: hasVideo, engine: "sidon", generative: true,
            music: false, outputs: outputs, bars: .synthetic(music: false))
        return JobResult(
            output: video ?? folder.appendingPathComponent("clip-enhanced.wav"), video: video,
            manifest: manifest ? stems : nil)
    }

    @Test func prefersTheOutputVideoWhileItIsOnDisk() {
        let output = folder.appendingPathComponent("clip-enhanced.mp4")
        let input = folder.appendingPathComponent("clip.mp4")
        let job = result(video: output, input: input.path, hasVideo: true)
        #expect(PreviewVideo.source(for: job) { _ in true } == output)
        // The output was moved or deleted: the input has the same picture.
        #expect(PreviewVideo.source(for: job) { $0 == input } == input)
        #expect(PreviewVideo.source(for: job) { _ in false } == nil)
    }

    @Test func audioOnlyOutputsFallBackToAVideoInput() {
        let input = folder.appendingPathComponent("clip.mov")
        #expect(PreviewVideo.source(for: result(video: nil, input: input.path, hasVideo: true)) { _ in true } == input)
        // An audio input (or cover art, which the engine doesn't count as video) has no picture.
        #expect(PreviewVideo.source(for: result(video: nil, input: input.path, hasVideo: false)) { _ in true } == nil)
    }

    @Test func needsAManifestWithALength() {
        let output = folder.appendingPathComponent("clip-enhanced.mp4")
        #expect(PreviewVideo.source(for: result(video: output, input: "", hasVideo: true, manifest: false)) { _ in true } == nil)
        #expect(PreviewVideo.source(for: result(video: output, input: "", hasVideo: true, duration: 0)) { _ in true } == nil)
    }

    @Test func playheadMapsOntoTheVideoTimelineAfterTheAudioStart() {
        let video = PreviewVideo(url: folder, aspect: 16 / 9, audioStart: 0.5, duration: 10)
        #expect(video.time(atPlayhead: 0) == 0.5)
        #expect(video.time(atPlayhead: 0.25) == 3)
        #expect(video.time(atPlayhead: 1) == 10.5)
        #expect(video.time(atPlayhead: 1.4) == 10.5)
        #expect(video.time(atPlayhead: -1) == 0.5)
    }

    @Test func seeksOnlyPastTheTolerance() {
        // Playing: the video runs on its own clock until it drifts 80 ms.
        #expect(!VideoSync.needsSeek(current: 3.05, expected: 3, isPlaying: true))
        #expect(VideoSync.needsSeek(current: 3.1, expected: 3, isPlaying: true))
        #expect(VideoSync.needsSeek(current: 2.9, expected: 3, isPlaying: true))
        // Paused: any visible difference moves the picture.
        #expect(VideoSync.needsSeek(current: 3.05, expected: 3, isPlaying: false))
        #expect(!VideoSync.needsSeek(current: 3.005, expected: 3, isPlaying: false))
        // A player with nothing loaded yet reports NaN.
        #expect(VideoSync.needsSeek(current: .nan, expected: 0, isPlaying: false))
    }

    @Test func displayAspectHandlesRotationAndPixelShape() {
        #expect(VideoSync.displayAspect(width: 1920, height: 1080, quarterTurn: false) == 1920.0 / 1080)
        #expect(VideoSync.displayAspect(width: 1920, height: 1080, quarterTurn: true) == 1080.0 / 1920)
        // Anamorphic DV: 720 × 480 pixels at 32:27 shows as 16:9-ish.
        #expect(abs(VideoSync.displayAspect(width: 720, height: 480, quarterTurn: false, pixelAspect: 32.0 / 27) - 1.778) < 0.001)
        #expect(VideoSync.displayAspect(width: 0, height: 0, quarterTurn: false) == VideoSync.fallbackAspect)
    }

    @Test func boxFillsTheWidthUpToTheMaximumHeight() {
        #expect(VideoSync.height(aspect: 16 / 9, width: 274) == 154)
        // Portrait is capped and pillarboxed.
        #expect(VideoSync.height(aspect: 9 / 16, width: 274) == 200)
        #expect(VideoSync.height(aspect: 9 / 16, width: 274, maxHeight: 120) == 120)
        #expect(VideoSync.height(aspect: .nan, width: 274) == 154)
    }
}
