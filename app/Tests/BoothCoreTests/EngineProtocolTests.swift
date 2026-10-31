import Foundation
import Testing
@testable import BoothCore

@Suite("Engine event decoding")
struct EngineEventDecoderTests {
    @Test func decodesHello() {
        let event = EngineEventDecoder.decode(line: #"{"event":"hello","protocol":1,"version":"0.1.0"}"#)
        #expect(event == .hello(EngineHello(protocolVersion: 1, version: "0.1.0")))
    }

    @Test func decodesStartFromTheSpec() throws {
        let line = #"""
        {"event":"start","input":"/abs/in.mp4","name":"in.mp4","duration":192.0,"has_video":true,"has_audio":true,"meta":"3:12 · MP4 · 1080p","engine":"sidon","eta":109.0}
        """#
        let event = try #require(EngineEventDecoder.decode(line: line))
        guard case .start(let start) = event else {
            Issue.record("expected start, got \(event)")
            return
        }
        #expect(start.input == "/abs/in.mp4")
        #expect(start.name == "in.mp4")
        #expect(start.duration == 192)
        #expect(start.hasVideo)
        #expect(start.hasAudio)
        #expect(start.meta == "3:12 · MP4 · 1080p")
        #expect(start.engine == "sidon")
        #expect(start.eta == 109)
    }

    @Test func decodesProgress() {
        let event = EngineEventDecoder.decode(
            line: #"{"event":"progress","progress":0.52,"stage":"restore","label":"Restoring the voice","eta":61.0}"#)
        #expect(event == .progress(EngineProgress(progress: 0.52, stage: "restore", label: "Restoring the voice", eta: 61)))
    }

    @Test func decodesDoneWithNullVideoAndMix() {
        let line = #"""
        {"event":"done","output":"/abs/in-enhanced.wav","wav":"/abs/in-enhanced.wav","video":null,"stems":"/abs/DIR","took":108.7,"music":true,"mix":{"speech":54,"background":10,"music":10}}
        """#
        let expected = EngineDone(
            output: "/abs/in-enhanced.wav", wav: "/abs/in-enhanced.wav", video: nil, stems: "/abs/DIR",
            took: 108.7, music: true, mix: .standard)
        #expect(EngineEventDecoder.decode(line: line) == .done(expected))
    }

    @Test func decodesBareSetupDone() {
        #expect(EngineEventDecoder.decode(line: #"{"event":"done"}"#) == .done(EngineDone()))
    }

    @Test func decodesErrors() {
        let event = EngineEventDecoder.decode(
            line: #"{"event":"error","code":"no_audio","message":"x.mov has a video track but no sound. Nothing was changed."}"#)
        #expect(event == .error(.noAudio(fileName: "x.mov")))
        // A newer engine's code survives; a missing code means internal.
        #expect(EngineEventDecoder.decode(line: #"{"event":"error","code":"gpu_melted","message":"m"}"#)
            == .error(JobError(code: "gpu_melted", message: "m")))
        #expect(EngineEventDecoder.decode(line: #"{"event":"error"}"#) == .error(JobError(code: .internal, message: "")))
    }

    @Test func decodesInfo() {
        let line = #"""
        {"event":"info","protocol":1,"version":"0.1.0","engines":["sidon","mossformer2","df3"],"ready":true,"missing":[],"python":"/abs/python"}
        """#
        let expected = EngineInfo(
            protocolVersion: 1, version: "0.1.0", engines: ["sidon", "mossformer2", "df3"],
            ready: true, missing: [], python: "/abs/python")
        #expect(EngineEventDecoder.decode(line: line) == .info(expected))
    }

    @Test func infoWithoutProtocolIsRejected() {
        #expect(EngineEventDecoder.decode(line: #"{"event":"info","ready":true}"#) == nil)
    }

    @Test func decodesSetupProgressWithFloatByteCounts() {
        let line = #"{"event":"setup","phase":"weights","label":"Downloading voice models","bytes_done":4.12e8,"bytes_total":1130000000,"eta":95.5}"#
        let expected = SetupProgress(
            phase: "weights", label: "Downloading voice models", bytesDone: 412_000_000,
            bytesTotal: 1_130_000_000, eta: 95.5)
        #expect(EngineEventDecoder.decode(line: line) == .setup(expected))
    }

    @Test func decodesSetupProgressFraction() {
        let line = #"{"event":"setup","phase":"engine","label":"Installing the voice engine","bytes_done":0,"bytes_total":1098065682,"eta":120.0,"progress":0.0731}"#
        guard case .setup(let progress) = EngineEventDecoder.decode(line: line) else {
            Issue.record("expected a setup event")
            return
        }
        #expect(progress.progress == 0.0731)
        #expect(SetupProgressInfo(progress).fraction == 0.0731)
    }

    @Test func decodesSetupStatus() {
        let line = #"{"event":"setup_status","ready":false,"missing":["sidon-venv","sidon-weights"],"bytes_total":1130000000}"#
        #expect(EngineEventDecoder.decode(line: line)
            == .setupStatus(SetupStatus(ready: false, missing: ["sidon-venv", "sidon-weights"], bytesTotal: 1_130_000_000)))
    }

    @Test func ignoresUnknownKeys() {
        let line = #"{"event":"progress","progress":0.1,"label":"Reading audio","future":{"nested":[1,2]},"x":null}"#
        #expect(EngineEventDecoder.decode(line: line) == .progress(EngineProgress(progress: 0.1, label: "Reading audio")))
    }

    @Test func unknownEventsDecodeAsUnknown() {
        #expect(EngineEventDecoder.decode(line: #"{"event":"telemetry","cpu":0.9}"#) == .unknown(name: "telemetry"))
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(EngineEventDecoder.decode(line: "  {\"event\":\"done\"}\r\n") == .done(EngineDone()))
    }

    @Test(arguments: [
        "",
        "   ",
        "Loading model…",
        "100%|██████████| 3/3",
        "[1, 2, 3]",
        "{",
        #"{"progress":0.5}"#,
        #"{"event":42}"#,
        #"{"event":"progress"}"#,
        #"{"event":"progress","progress":"half"}"#,
        #"{"event":"start","duration":"long"}"#,
        #"{"event":"setup","bytes_done":"lots"}"#,
        #"{"event":"setup_status"}"#,
    ])
    func garbageIsNil(line: String) {
        #expect(EngineEventDecoder.decode(line: line) == nil)
    }
}

@Suite("Line buffer")
struct LineBufferTests {
    @Test func splitsChunksIntoLines() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data(#"{"event":"he"#.utf8)) == [])
        #expect(buffer.append(Data("llo\"}\n{\"event\":\"done\"}\n{\"ev".utf8)) == [#"{"event":"hello"}"#, #"{"event":"done"}"#])
        #expect(buffer.finish() == #"{"ev"#)
        #expect(buffer.finish() == nil)
    }

    @Test func stripsCarriageReturnsAndKeepsEmptyLines() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("a\r\n\nb\n".utf8)) == ["a", "", "b"])
    }

    @Test func keepsMultibyteCharactersSplitAcrossChunks() {
        var buffer = LineBuffer()
        let bytes = Array("3:12 · MP4\n".utf8)
        let middle = bytes.firstIndex(of: 0xC2)! + 1 // split inside "·"
        #expect(buffer.append(Data(bytes[..<middle])) == [])
        #expect(buffer.append(Data(bytes[middle...])) == ["3:12 · MP4"])
    }
}

@Suite("Run options and stages")
struct RunOptionsTests {
    let input = URL(fileURLWithPath: "/Users/me/Movies/in take.mp4")
    let output = URL(fileURLWithPath: "/Users/me/Movies/in take-enhanced.mp4")
    let stems = URL(fileURLWithPath: "/Users/me/Library/Caches/Booth/jobs/ABC", isDirectory: true)

    @Test func defaultArguments() {
        let options = RunOptions(output: output, stemsDirectory: stems)
        #expect(options.arguments(input: input) == [
            "enhance", "/Users/me/Movies/in take.mp4", "--events",
            "--stems-dir", "/Users/me/Library/Caches/Booth/jobs/ABC",
            "-o", "/Users/me/Movies/in take-enhanced.mp4",
            "--engine", "sidon",
            "-s", "54", "-b", "10", "-m", "10",
        ])
    }

    @Test func optionalFlags() {
        let options = RunOptions(
            output: output, stemsDirectory: stems, engine: .quick, splitMusic: false, keepVideo: false,
            mix: Mix(speech: 80, background: 0, music: 100))
        let args = options.arguments(input: input)
        #expect(args.contains("--no-split"))
        #expect(args.contains("--audio-only"))
        #expect(Array(args.drop { $0 != "--engine" }.prefix(2)) == ["--engine", "df3"])
        #expect(Array(args.suffix(6)) == ["-s", "80", "-b", "0", "-m", "100"])
    }

    @Test func wavOutputsAreAlwaysAudioOnly() {
        // An .m4a with a video track: the app reserved only the .wav, so the engine must not
        // remux into "<stem>-enhanced.m4a".
        let audio = URL(fileURLWithPath: "/Users/me/rec.m4a")
        let wav = RunOptions(output: URL(fileURLWithPath: "/Users/me/rec-enhanced.wav"), stemsDirectory: stems)
        #expect(wav.arguments(input: audio).contains("--audio-only"))
        let upper = RunOptions(output: URL(fileURLWithPath: "/Users/me/rec-enhanced.WAV"), stemsDirectory: stems)
        #expect(upper.arguments(input: audio).contains("--audio-only"))

        // Video kept as video: no flag.
        #expect(!RunOptions(output: output, stemsDirectory: stems, keepVideo: true).arguments(input: input).contains("--audio-only"))
        // Video turned off: the flag, whatever the output is called.
        #expect(RunOptions(output: output, stemsDirectory: stems, keepVideo: false).arguments(input: input).contains("--audio-only"))
        let videoToWav = RunOptions(output: URL(fileURLWithPath: "/Users/me/Movies/in take-enhanced.wav"), stemsDirectory: stems, keepVideo: false)
        #expect(videoToWav.arguments(input: input).filter { $0 == "--audio-only" }.count == 1)
    }

    @Test func engineChoiceMapping() {
        #expect(EngineChoice.allCases.map(\.engineName) == ["sidon", "mossformer2", "df3"])
        #expect(EngineChoice.allCases.map(\.label) == ["Studio", "Clean", "Quick"])
        #expect(EngineChoice(engineName: "mossformer2") == .clean)
        #expect(EngineChoice(engineName: "studio") == nil)
        #expect(EngineChoice.studio.note == "Rebuilds the voice at 48 kHz. Best quality, about half real time.")
        #expect(EngineChoice.clean.note == "Removes noise without rebuilding the voice. Faster.")
        #expect(EngineChoice.quick.note == "Light noise removal in seconds. Good for drafts.")
    }

    @Test func stagePlansRenormalise() {
        let studio = EngineStage.plan(engine: .studio, splitMusic: true)
        #expect(studio.map(\.label) == ["Reading audio", "Separating music", "Restoring the voice", "Removing clicks", "Writing the file"])
        #expect(abs(studio.reduce(0) { $0 + $1.weight } - 1) < 1e-9)

        let quickNoSplit = EngineStage.plan(engine: .quick, splitMusic: false)
        #expect(quickNoSplit.map(\.id) == ["decode", "restore", "cleanup", "write"])
        #expect(quickNoSplit.map(\.label) == ["Reading audio", "Removing noise", "Cleaning up", "Writing the file"])
        #expect(abs(quickNoSplit[1].weight - 0.40 / 0.60) < 1e-9)
    }

    @Test func stageLookupMatchesThePrototype() {
        let stages = EngineStage.studio
        #expect(EngineStage.stage(at: 0, in: stages)?.label == "Reading audio")
        #expect(EngineStage.stage(at: 0.03, in: stages)?.label == "Separating music")
        #expect(EngineStage.stage(at: 0.48, in: stages)?.label == "Restoring the voice")
        #expect(EngineStage.stage(at: 0.9, in: stages)?.label == "Removing clicks")
        #expect(EngineStage.stage(at: 1, in: stages)?.label == "Writing the file")
    }
}
