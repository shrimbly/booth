import Foundation
import Testing
@testable import BoothCore

@Suite("Job")
struct JobTests {
    let input = URL(fileURLWithPath: "/Users/me/Movies/interview-take3.mp4")

    @Test func startsQueuedWithTheFileName() {
        let job = Job(input: input)
        #expect(job.state == .queued)
        #expect(job.name == "interview-take3.mp4")
        #expect(job.progress == 0)
        #expect(job.hasVideo)
        #expect(job.mediaKind == .video)
        #expect(Job(input: URL(fileURLWithPath: "/a/memo.m4a")).hasVideo == false)
    }

    @Test func foldsAFullRun() throws {
        var job = Job(input: input)
        job.apply(.hello(EngineHello(version: "0.1.0")))
        #expect(job.state == .queued)

        job.apply(.start(EngineStart(duration: 192, hasVideo: true, meta: "3:12 · MP4 · 1080p", eta: 109)))
        #expect(job.state == .working)
        #expect(job.duration == 192)
        #expect(job.meta == "3:12 · MP4 · 1080p")
        #expect(job.eta == 109)

        job.apply(.progress(EngineProgress(progress: 0.52, stage: "restore", label: "Restoring the voice", eta: 61)))
        #expect(job.progress == 0.52)
        #expect(job.stageLabel == "Restoring the voice")
        #expect(job.eta == 61)

        job.apply(.done(EngineDone(
            output: "/Users/me/Movies/interview-take3-enhanced.mp4", wav: "/Users/me/Movies/interview-take3-enhanced.wav",
            video: "/Users/me/Movies/interview-take3-enhanced.mp4", stems: "/cache/job", took: 108.7, music: true,
            mix: Mix(speech: 60, background: 10, music: 10))))
        #expect(job.state == .done)
        #expect(job.progress == 1)
        let result = try #require(job.result)
        #expect(result.output.path == "/Users/me/Movies/interview-take3-enhanced.mp4")
        #expect(result.wav?.lastPathComponent == "interview-take3-enhanced.wav")
        #expect(result.stems?.path == "/cache/job")
        #expect(result.took == 108.7)
        #expect(result.music)
        #expect(result.mix.speech == 60)
    }

    @Test func progressNeverGoesBackwardsAndIsClamped() {
        var job = Job(input: input)
        job.apply(.progress(EngineProgress(progress: 0.6, label: "Restoring the voice")))
        job.apply(.progress(EngineProgress(progress: 0.4, label: "Removing clicks")))
        #expect(job.progress == 0.6)
        #expect(job.stageLabel == "Removing clicks")
        job.apply(.progress(EngineProgress(progress: 7)))
        #expect(job.progress == 1)
        #expect(job.stageLabel == "Removing clicks")
    }

    @Test func doneWithoutAnOutputIsAnEngineFailure() {
        var job = Job(input: input)
        job.apply(.done(EngineDone()))
        #expect(job.state == .failed)
        #expect(job.error?.code == .engineFailed)
        #expect(job.result == nil)
    }

    @Test func errorsFailAndCancellationCancels() {
        var failed = Job(input: input)
        failed.apply(.error(.noAudio(fileName: "interview-take3.mp4")))
        #expect(failed.state == .failed)
        #expect(failed.error?.message == "interview-take3.mp4 has a video track but no sound. Nothing was changed.")

        var cancelled = Job(input: input)
        cancelled.apply(.error(JobError(code: .cancelled, message: "Cancelled.")))
        #expect(cancelled.state == .cancelled)
    }

    @Test func finishedJobsIgnoreLateEvents() {
        var job = Job(input: input)
        job.apply(.error(JobError(code: .engineFailed, message: "boom")))
        job.apply(.progress(EngineProgress(progress: 0.9)))
        job.apply(.done(EngineDone(output: "/x.wav")))
        #expect(job.state == .failed)
        #expect(job.progress == 0)
        #expect(job.result == nil)
    }

    @Test func finishedStates() {
        #expect(JobState.allCases.filter(\.isFinished) == [.done, .failed, .cancelled])
    }

    @Test func resultFallsBackToSyntheticBars() {
        let result = JobResult(output: URL(fileURLWithPath: "/x.wav"), music: false)
        #expect(result.waveformSource == .synthetic(music: false))
        #expect(result.curve == .standard)
    }
}
