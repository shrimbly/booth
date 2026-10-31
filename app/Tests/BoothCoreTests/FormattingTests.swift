import Testing
@testable import BoothCore

@Suite("Formatting")
struct FormattingTests {
    @Test(arguments: [
        (0.0, 0), (0.004, 0), (0.005, 1), (0.48, 48), (0.485, 49), (0.52, 52), (0.999, 100), (1.0, 100), (1.7, 100), (-1.0, 0),
    ])
    func percent(fraction: Double, expected: Int) {
        #expect(Formatting.percent(fraction) == expected)
    }

    @Test(arguments: [
        (0.0, "under a minute left"),
        (39.9, "under a minute left"),
        (40.0, "about 1 min left"),
        (89.9, "about 1 min left"),
        (90.0, "about 2 min left"),
        (149.0, "about 2 min left"),
        (150.0, "about 3 min left"),
        (600.0, "about 10 min left"),
    ])
    func etaPhrase(seconds: Double, expected: String) {
        #expect(Formatting.etaPhrase(seconds: seconds) == expected)
    }

    @Test func statusLine() {
        #expect(Formatting.statusLine(progress: 0.52, stageLabel: "Restoring the voice", eta: 61)
            == "52% · Restoring the voice · about 1 min left")
        #expect(Formatting.statusLine(progress: 0.48, stageLabel: "Restoring the voice", eta: 109 * 0.52)
            == "48% · Restoring the voice · about 1 min left")
        #expect(Formatting.statusLine(progress: 0, stageLabel: "", eta: nil) == "0% · Reading audio")
        #expect(Formatting.statusLine(progress: 0.97, stageLabel: "Writing the file", eta: 3)
            == "97% · Writing the file · under a minute left")
    }

    @Test(arguments: [
        (0.0, "0:00"), (8.0, "0:08"), (59.4, "0:59"), (59.5, "1:00"), (108.7, "1:49"), (109.0, "1:49"), (192.0, "3:12"),
        (3725.0, "62:05"), (-3.0, "0:00"),
    ])
    func clock(seconds: Double, expected: String) {
        #expect(Formatting.clock(seconds) == expected)
    }

    @Test func queueLine() {
        #expect(Formatting.queueLine([]) == nil)
        #expect(Formatting.queueLine(["a.wav"]) == "Next: a.wav")
        #expect(Formatting.queueLine(["a.wav", "b.mp4"]) == "Next: a.wav and 1 more")
        #expect(Formatting.queueLine(["a.wav", "b.mp4", "c.mov"]) == "Next: a.wav and 2 more")
    }

    @Test func backgroundJobLabel() {
        #expect(Formatting.backgroundJobLabel(name: "voice-memo.m4a", progress: 0.34) == "In the booth: voice-memo.m4a · 34%")
    }

    @Test(arguments: [
        (Int64(0), "0 MB"),
        (Int64(412_000_000), "412 MB"),
        (Int64(999_400_000), "999 MB"),
        (Int64(999_600_000), "1.00 GB"),
        (Int64(1_050_000_000), "1.05 GB"),
        (Int64(1_130_000_000), "1.13 GB"),
    ])
    func size(bytes: Int64, expected: String) {
        #expect(Formatting.size(bytes: bytes) == expected)
    }

    @Test func setupBytes() {
        #expect(Formatting.setupBytes(done: 412_000_000, total: 1_130_000_000) == "412 MB of 1.13 GB")
        #expect(Formatting.setupBytes(done: 1_050_000_000, total: 1_130_000_000) == "1.05 GB of 1.13 GB")
    }

    @Test func setupTimeLeft() {
        #expect(Formatting.setupTimeLeft(fraction: 0.36, eta: 110) == "about 2 min left")
        #expect(Formatting.setupTimeLeft(fraction: 0.9, eta: 10) == "about 1 min left")
        #expect(Formatting.setupTimeLeft(fraction: 0.9, eta: 0) == "about 1 min left")
        #expect(Formatting.setupTimeLeft(fraction: 0.1, eta: 600) == "about 10 min left")
        #expect(Formatting.setupTimeLeft(fraction: 1, eta: 30) == "Done")
        #expect(Formatting.setupTimeLeft(fraction: 0.1, eta: nil) == "")
    }

    @Test func meta() {
        #expect(Formatting.meta(duration: 192, fileExtension: "mp4", height: 1080) == "3:12 · MP4 · 1080p")
        #expect(Formatting.meta(duration: 48, fileExtension: "m4a") == "0:48 · M4A")
        #expect(Formatting.meta(duration: 21, fileExtension: "MOV", height: 0) == "0:21 · MOV")
    }

    @Test func errorCopy() {
        #expect(Formatting.errorTitle(for: .noAudio) == "This file has no audio")
        #expect(Formatting.errorTitle(for: .decodeFailed) == "Booth couldn't read this file")
        #expect(Formatting.errorTitle(for: .decodeFailed, fileCount: 2) == "Booth couldn't read these files")
        #expect(Formatting.errorTitle(for: .noAudio, fileCount: 2) == "This file has no audio")
        #expect(Formatting.errorTitle(for: .engineFailed) == "Something went wrong")
        #expect(Formatting.errorTitle(for: .internal) == "Something went wrong")
        #expect(Formatting.errorTitle(for: "brand_new") == "Something went wrong")

        let noAudio = JobError.noAudio(fileName: "b-roll-silent.mov")
        #expect(Formatting.errorBody(for: noAudio) == "b-roll-silent.mov has a video track but no sound. Nothing was changed.")
        let crash = JobError(code: .internal, message: "  RuntimeError: out of memory  \nTraceback (most recent call last):\n  File …")
        #expect(Formatting.errorBody(for: crash) == "RuntimeError: out of memory")
        #expect(Formatting.errorBody(for: JobError(code: .engineFailed, message: "")) == "")
    }

    @Test func notificationAndCapsuleCopy() {
        #expect(Formatting.notificationBody(name: "interview-take3.mp4") == "interview-take3.mp4 is out of the booth.")
        #expect(Formatting.capsuleText(enqueuedNames: ["voice-memo.m4a"]) == "In the booth: voice-memo.m4a")
        #expect(Formatting.capsuleText(enqueuedNames: ["a.wav", "b.wav", "c.wav"]) == "In the booth: 3 files")
        #expect(Formatting.capsuleText(enqueuedNames: []) == "Select audio or video in Finder first")
        #expect(Formatting.setupFailedTitle == "Setup didn't finish")
    }

    @Test func unsupportedFileCopy() {
        #expect(Formatting.unsupportedFileBody(name: "notes.pdf") == "notes.pdf isn't an audio or video file Booth can read. Nothing was changed.")
        #expect(Formatting.unsupportedFileBody(names: ["notes.pdf", "a.txt", "b.zip"])
            == "notes.pdf and 2 more aren't audio or video files Booth can read. Nothing was changed.")
        #expect(Formatting.unsupportedSelectionText(count: 1) == "Booth can't enhance the selected file")
        #expect(Formatting.unsupportedSelectionText(count: 3) == "Booth can't enhance the selected files")
        #expect(Formatting.remixFailedBody(name: "a.wav") == "The new mix for a.wav wasn't saved. Its file still has the previous mix.")
    }

    @Test func engineWaitingCopy() {
        #expect(Formatting.engineWaitingTitle == "Waiting for the engine")
        #expect(Formatting.engineWaitingBody(folder: "~/Documents/projects/booth")
            == "Booth's engine in ~/Documents/projects/booth is taking a while to start. If macOS is asking whether Booth may access that folder, choose Allow.")
        #expect(Formatting.engineUnresponsiveMessage(folder: "~/Documents/sv")
            == "Booth's engine in ~/Documents/sv isn't answering. If macOS asked whether Booth may access that folder, choose Allow, then click Try again.")
    }

    @Test(arguments: [
        ("/Users/me/Documents/projects/booth/.venv/bin/booth", "~/Documents/projects/booth"),
        ("/Users/me/.local/bin/booth", "~/.local/bin"),
        ("/Users/me/booth", "~"),
        ("/Users/meadow/sv/.venv/bin/booth", "/Users/meadow/sv"),
        ("/opt/sv/.venv/bin/booth", "/opt/sv"),
        ("/booth", "/"),
    ])
    func engineFolder(path: String, expected: String) {
        #expect(Formatting.engineFolder(executablePath: path, home: "/Users/me") == expected)
        #expect(Formatting.engineFolder(executablePath: path, home: "/Users/me/") == expected)
    }
}
