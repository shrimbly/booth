import BoothCore
import Foundation
import Testing
@testable import Booth

@Suite("Done screen")
@MainActor
struct DoneScreenTests {
    @Test func doneReturnsToTheDropZoneAndStaysThere() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()
        #expect(h.model.effectiveScreen == .done)
        h.model.togglePlay()
        #expect(h.model.isPlaying)

        h.model.closeDone()
        #expect(h.model.effectiveScreen == .idle)
        #expect(h.model.isOpen)
        #expect(!h.model.isPlaying)
        #expect(h.model.focusID == nil)
        // The job and its output are left alone.
        #expect(h.model.jobs.map(\.state) == [.done])

        h.model.close()
        h.model.open()
        #expect(h.model.effectiveScreen == .idle)
    }

    @Test func doneWithAFileStillInTheBoothShowsIt() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        try h.finishActive()
        #expect(h.model.effectiveScreen == .done)
        let next = try #require(h.model.activeJob)

        h.model.closeDone()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.focusID == next.id)
    }

    @Test func doneOnlyActsOnTheDoneScreen() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        h.model.closeDone()
        #expect(h.model.effectiveScreen == .working)
        #expect(h.model.focusID == h.model.activeID)
    }

    @Test func mixSlidersStartHiddenForEachJob() async throws {
        let h = await Harness.ready()
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()
        #expect(!h.model.isMixOpen)
        h.model.toggleMix()
        #expect(h.model.isMixOpen)

        h.model.closeDone()
        h.model.enqueue([h.file("b.wav")])
        try h.finishActive()
        #expect(h.model.effectiveScreen == .done)
        #expect(!h.model.isMixOpen)
    }

    @Test func aSaveStillRunningShowsTheSliders() async throws {
        let h = await Harness.ready(remixing: FakeRemixer(delay: .seconds(30)))
        h.model.enqueue([h.file("a.wav"), h.file("b.wav")])
        try h.finishActive()
        let a = try #require(h.model.jobs.first)
        try h.finishActive()
        let b = try #require(h.model.jobs.last)

        h.model.openJob(a.id)
        h.model.toggleMix()
        h.model.setMix(Mix(speech: 80, background: 0, music: 10))
        h.model.saveMix()
        #expect(h.model.isSaving)

        h.model.openJob(b.id)
        #expect(!h.model.isMixOpen)
        h.model.openJob(a.id)
        #expect(h.model.isMixOpen)
    }

    @Test func audioJobsHaveNoVideo() async throws {
        let h = await Harness.ready(video: FixedVideoInspector(traits: VideoTraits(aspect: 16 / 9, audioStart: 0)))
        h.model.open()
        h.model.enqueue([h.file("a.wav")])
        try h.finishActive()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!h.model.canShowVideo)
        h.model.toggleVideo()
        #expect(!h.settings.showVideo)
        #expect(h.model.shownVideo == nil)
    }

    @Test func aVideoJobOffersItsPictureAndTheChoiceIsRemembered() async throws {
        let folder = try VideoJobFolder()
        defer { folder.remove() }
        let h = await Harness.ready(video: FixedVideoInspector(traits: VideoTraits(aspect: 9 / 16, audioStart: 0.25)))
        h.model.open()

        try folder.finish(h, name: "clip.mp4")
        try await h.waitUntil { h.model.canShowVideo }
        #expect(h.model.effectiveScreen == .done)
        #expect(h.model.previewVideo == PreviewVideo(url: folder.video, aspect: 9 / 16, audioStart: 0.25, duration: 12))
        // Off until asked for.
        #expect(h.model.shownVideo == nil)

        h.model.toggleVideo()
        #expect(h.settings.showVideo)
        #expect(h.model.shownVideo?.url == folder.video)

        // The next video job shows its picture straight away.
        h.model.closeDone()
        try folder.finish(h, name: "clip2.mp4")
        try await h.waitUntil { h.model.canShowVideo }
        #expect(h.model.shownVideo != nil)
    }

    @Test func aFileWithoutAPictureOffersNoVideo() async throws {
        let folder = try VideoJobFolder()
        defer { folder.remove() }
        let h = await Harness.ready(video: FixedVideoInspector(traits: nil))
        h.model.open()
        try folder.finish(h, name: "clip.mp4")
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.model.effectiveScreen == .done)
        #expect(!h.model.canShowVideo)
    }
}

/// A stems folder with a manifest and an output video on disk, as a real video job leaves them.
private struct VideoJobFolder {
    let root: URL
    var video: URL { root.appendingPathComponent("clip-enhanced.mp4") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("booth-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: video)
        let manifest = StemsManifest(
            input: root.appendingPathComponent("clip.mp4").path, name: "clip.mp4", duration: 12, hasVideo: true,
            engine: "sidon", generative: true, music: false,
            outputs: StemsManifest.Outputs(wav: root.appendingPathComponent("clip-enhanced.wav").path, video: video.path),
            bars: .synthetic(music: false))
        try manifest.encoded().write(to: root.appendingPathComponent(StemsManifest.fileName))
    }

    /// Enqueues `name` and finishes it with this folder's video and stems.
    @MainActor
    func finish(_ h: Harness, name: String) throws {
        h.model.enqueue([h.file(name)])
        let active = try #require(h.model.activeJob)
        h.runner.send(
            .done(EngineDone(output: video.path, video: video.path, stems: root.path, took: 5, mix: .standard)),
            to: active.id)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
