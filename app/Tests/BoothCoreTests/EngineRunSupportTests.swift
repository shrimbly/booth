import Foundation
import Testing
@testable import BoothCore

@Suite("Stderr tail")
struct OutputTailTests {
    @Test func keepsOnlyTheLastLines() {
        var tail = OutputTail(maxLines: 3)
        for i in 1...5 { tail.append("line \(i)") }
        #expect(tail.lines == ["line 3", "line 4", "line 5"])
        #expect(tail.text == "line 3\nline 4\nline 5")
    }

    @Test func collapsesProgressBarRedrawsAndDropsBlanks() {
        var tail = OutputTail()
        #expect(tail.append(" 10%|█    |\r 50%|█████ |\r100%|██████████|") == "100%|██████████|")
        #expect(tail.append("   ") == nil)
        #expect(tail.append("\r\r") == nil)
        #expect(tail.lines == ["100%|██████████|"])
    }

    @Test func clipsVeryLongLines() {
        var tail = OutputTail(maxLineLength: 10)
        #expect(tail.append(String(repeating: "x", count: 50)) == String(repeating: "x", count: 10) + "…")
    }

    @Test func meaningfulLineSkipsTracebackFramesAndBars() {
        var tail = OutputTail()
        tail.append("Traceback (most recent call last):")
        tail.append("  File \"/x/pipeline.py\", line 12, in run")
        tail.append("RuntimeError: MPS backend out of memory")
        tail.append(" 80%|████████  | 4/5")
        #expect(tail.lastMeaningfulLine == "RuntimeError: MPS backend out of memory")
    }

    @Test func failureMessageLeadsWithTheReason() {
        var tail = OutputTail()
        tail.append("loading model")
        tail.append("Segmentation fault")
        let message = EngineFailure.message(exitStatus: 139, signaled: false, tail: tail)
        #expect(message.hasPrefix("The engine stopped unexpectedly: Segmentation fault\n\n"))
        #expect(message.hasSuffix("loading model\nSegmentation fault"))
        #expect(Formatting.errorBody(for: JobError(code: .engineFailed, message: message)) == "The engine stopped unexpectedly: Segmentation fault")
    }

    @Test func failureMessageWithoutStderr() {
        #expect(EngineFailure.message(exitStatus: 9, signaled: true, tail: OutputTail()) == "The engine stopped unexpectedly (signal 9).")
        #expect(EngineFailure.message(exitStatus: 3, signaled: false, tail: OutputTail()) == "The engine stopped unexpectedly (exit status 3).")
    }
}

@Suite("Job cache policy")
struct JobCachePolicyTests {
    func entries(_ count: Int) -> [JobCachePolicy.Entry] {
        (0..<count).map { i in
            JobCachePolicy.Entry(url: URL(fileURLWithPath: "/cache/jobs/\(i)"), modified: Date(timeIntervalSince1970: Double(i)))
        }
    }

    @Test func keepsTheNewestTen() {
        let doomed = JobCachePolicy.directoriesToRemove(entries(13).shuffled())
        #expect(Set(doomed.map(\.lastPathComponent)) == ["0", "1", "2"])
    }

    @Test func nothingToDoUnderTheLimit() {
        #expect(JobCachePolicy.directoriesToRemove(entries(10)).isEmpty)
        #expect(JobCachePolicy.directoriesToRemove([]).isEmpty)
    }

    @Test func neverRemovesProtectedDirectories() {
        let doomed = JobCachePolicy.directoriesToRemove(entries(5), keep: 2, protected: ["/cache/jobs/0"])
        // 0 is protected and takes no slot; 4 and 3 keep theirs, 2 and 1 go.
        #expect(Set(doomed.map(\.lastPathComponent)) == ["1", "2"])
    }

    @Test func protectedJobsSurviveTenNewerOnes() {
        // The session's first three jobs are still listed; 12 newer folders are not.
        let protected: Set<String> = ["/cache/jobs/0", "/cache/jobs/1", "/cache/jobs/2/"]
        let doomed = JobCachePolicy.directoriesToRemove(entries(15).shuffled(), protected: protected)
        #expect(Set(doomed.map(\.lastPathComponent)) == ["3", "4"])
    }

    @Test func launchKeepsNothingButRecentFolders() {
        // keep 0, sparing folders modified after t = 11 (another Booth's live job).
        let doomed = JobCachePolicy.directoriesToRemove(entries(13), keep: 0, sparingAfter: Date(timeIntervalSince1970: 10.5))
        #expect(Set(doomed.map(\.lastPathComponent)) == Set((0...10).map(String.init)))
        #expect(JobCachePolicy.launchGracePeriod == 3600)
    }
}

@Suite("Setup progress")
struct SetupProgressCombinerTests {
    @Test func modelsOnlyIsAPassthrough() {
        var combiner = SetupProgressCombiner(installBytesExpected: 0, modelBytesTotal: 0)
        let event = SetupProgress(phase: "weights", label: "Downloading voice models", bytesDone: 412_000_000, bytesTotal: 1_130_000_000, eta: 110)
        #expect(combiner.downloading(event) == event)
    }

    @Test func installComesFirstAndNeverOvershoots() {
        let combiner = SetupProgressCombiner(installBytesExpected: 600_000_000, modelBytesTotal: 1_130_000_000)
        let early = combiner.installing(bytesInstalled: 150_000_000, elapsed: 10)
        #expect(early.bytesDone == 150_000_000)
        #expect(early.bytesTotal == 1_730_000_000)
        #expect(early.label == "Installing the engine")
        #expect(early.eta == 1_580_000_000.0 / 15_000_000)
        let late = combiner.installing(bytesInstalled: 900_000_000, elapsed: 60)
        #expect(late.bytesDone == 588_000_000)
    }

    @Test func noEstimateInTheFirstSeconds() {
        let combiner = SetupProgressCombiner(installBytesExpected: 600_000_000)
        #expect(combiner.installing(bytesInstalled: 1_000_000, elapsed: 1).eta == nil)
    }

    @Test func modelBytesFollowTheInstall() {
        var combiner = SetupProgressCombiner(installBytesExpected: 600_000_000)
        let combined = combiner.downloading(SetupProgress(phase: "weights", label: "Downloading voice models", bytesDone: 100, bytesTotal: 1_000_000_000, eta: 30))
        #expect(combined.bytesDone == 600_000_100)
        #expect(combined.bytesTotal == 1_600_000_000)
        #expect(combined.eta == 30)
        #expect(combined.label == "Downloading voice models")
        #expect(combiner.modelBytesTotal == 1_000_000_000)
    }

    @Test func engineProgressIsPlacedAfterTheInstall() {
        var combiner = SetupProgressCombiner(installBytesExpected: 500_000_000)
        let combined = combiner.downloading(SetupProgress(bytesDone: 0, bytesTotal: 1_500_000_000, progress: 0.2))
        // 500 MB of install plus 20 % of 1.5 GB, out of 2 GB.
        #expect(combined.progress.map { abs($0 - 0.4) < 1e-12 } == true)
    }

    @Test func engineProgressPassesThroughWithoutAnInstall() {
        var combiner = SetupProgressCombiner(installBytesExpected: 0, modelBytesTotal: 0)
        let event = SetupProgress(phase: "engine", label: "Installing the voice engine", bytesDone: 0, bytesTotal: 1_098_065_682, eta: 90, progress: 0.12)
        #expect(combiner.downloading(event) == event)
    }

    @Test func nothingToDownloadDropsTheEstimate() {
        var combiner = SetupProgressCombiner(installBytesExpected: 500_000_000)
        let combined = combiner.downloading(SetupProgress(bytesDone: 0, bytesTotal: 0, progress: 1))
        #expect(combined.bytesTotal == 500_000_000)
        #expect(combined.progress == 1)
    }
}

@Suite("WAV layout")
struct WAVLayoutTests {
    /// A minimal RIFF/WAVE file, optionally with an extra chunk before `data`.
    static func wav(tag: UInt16, bits: UInt16, channels: UInt16 = 1, rate: UInt32 = 48_000, samples: Data, extraChunk: Bool = false, extensible: Bool = false) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var fmt = Data()
        fmt += le(extensible ? UInt16(0xFFFE) : tag) + le(channels) + le(rate)
        fmt += le(rate * UInt32(channels) * UInt32(bits / 8)) + le(channels * bits / 8) + le(bits)
        if extensible {
            fmt += le(UInt16(22)) + le(bits) + le(UInt32(4)) + le(tag) + Data(repeating: 0, count: 14)
        }
        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
        if extraChunk {
            body += Data("PEAK".utf8) + le(UInt32(3)) + Data([1, 2, 3, 0]) // odd size + pad byte
        }
        body += Data("data".utf8) + le(UInt32(samples.count)) + samples
        return Data("RIFF".utf8) + le(UInt32(body.count)) + body
    }

    static func floats(_ values: [Float]) -> Data {
        values.reduce(into: Data()) { data, value in
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data += Data($0) }
        }
    }

    @Test func floatMonoWithExtraChunks() throws {
        let file = Self.wav(tag: 3, bits: 32, samples: Self.floats([0.5, -0.25, 1]), extraChunk: true)
        let layout = try WAVLayout.parse(file)
        #expect(layout.format == .float32)
        #expect(layout.channels == 1 && layout.sampleRate == 48_000)
        #expect(layout.frameCount == 3)
        file.withUnsafeBytes { bytes in
            #expect(layout.sample(in: bytes, frame: 0) == 0.5)
            #expect(layout.sample(in: bytes, frame: 1) == -0.25)
            #expect(layout.sample(in: bytes, frame: 2) == 1)
        }
    }

    @Test func pcm16Stereo() throws {
        var samples = Data()
        for value: Int16 in [16384, -16384, 32767, 0] {
            withUnsafeBytes(of: value.littleEndian) { samples += Data($0) }
        }
        let file = Self.wav(tag: 1, bits: 16, channels: 2, rate: 44_100, samples: samples)
        let layout = try WAVLayout.parse(file)
        #expect(layout.format == .int16 && layout.channels == 2 && layout.frameCount == 2)
        file.withUnsafeBytes { bytes in
            #expect(layout.sample(in: bytes, frame: 0, channel: 0) == 0.5)
            #expect(layout.sample(in: bytes, frame: 0, channel: 1) == -0.5)
        }
    }

    @Test func pcm24() throws {
        let samples = Data([0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]) // +0.5, −0.5
        let file = Self.wav(tag: 1, bits: 24, samples: samples)
        let layout = try WAVLayout.parse(file)
        file.withUnsafeBytes { bytes in
            #expect(layout.sample(in: bytes, frame: 0) == 0.5)
            #expect(layout.sample(in: bytes, frame: 1) == -0.5)
        }
    }

    @Test func extensibleFormat() throws {
        let layout = try WAVLayout.parse(Self.wav(tag: 3, bits: 32, samples: Self.floats([0, 0]), extensible: true))
        #expect(layout.format == .float32 && layout.frameCount == 2)
    }

    @Test func dataSizeLargerThanTheFileIsClamped() throws {
        var file = Self.wav(tag: 3, bits: 32, samples: Self.floats([1, 2, 3, 4]))
        file.removeLast(4)
        let layout = try WAVLayout.parse(file)
        #expect(layout.frameCount == 3)
    }

    @Test func rejectsWhatItCannotRead() {
        #expect(throws: WAVLayout.ParseError.notWAV) { try WAVLayout.parse(Data("hello world, not a wav".utf8)) }
        #expect(throws: WAVLayout.ParseError.unsupportedFormat(tag: 2, bitsPerSample: 4)) {
            try WAVLayout.parse(Self.wav(tag: 2, bits: 4, samples: Data([0])))
        }
    }
}

@Suite("Self-test flags")
struct SelfTestFlagTests {
    @Test func cancelAfterAndRemix() {
        let options = LaunchOptions.parse(
            ["--selftest-engine", "/a/in.wav", "--selftest-cancel-after", "2.5", "--selftest-remix"], currentDirectory: "/")
        #expect(options.selfTestInput?.path == "/a/in.wav")
        #expect(options.selfTestCancelAfter == 2.5)
        #expect(options.selfTestRemix)
        #expect(options.problems.isEmpty)
    }

    @Test func badCancelDelayIsAProblem() {
        let options = LaunchOptions.parse(["--selftest-cancel-after", "soon"], currentDirectory: "/")
        #expect(options.selfTestCancelAfter == nil)
        #expect(options.problems.count == 1)
    }
}
