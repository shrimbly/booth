import Foundation
import Testing
@testable import BoothCore

@Suite("Stems manifest")
struct StemsManifestTests {
    static func bins(_ value: Double) -> String {
        "[" + Array(repeating: String(value), count: 56).joined(separator: ",") + "]"
    }

    static let specJSON = """
    {"protocol":1,"input":"/abs/in.mp4","name":"in.mp4","duration":192.0,"has_video":true,"engine":"sidon",
     "generative":true,"music":true,"sample_rate":48000,
     "outputs":{"wav":"/abs/in-enhanced.wav","video":"/abs/in-enhanced.mp4"},
     "mix":{"speech":54,"background":10,"music":10},
     "settings":{"linear":false,"level":false,"loudness":"auto","crf":null,"audio_only":false},
     "preview_gain":1.83,
     "bars":{"clean":\(bins(0.5)),"vocals":\(bins(0.4)),"background":\(bins(0.1)),"music":\(bins(0.2)),"original":\(bins(0.6))},
     "added_later":"ignored"}
    """

    @Test func decodesTheSpecExample() throws {
        let manifest = try StemsManifest.decode(Data(Self.specJSON.utf8))
        #expect(manifest.protocolVersion == 1)
        #expect(manifest.input == "/abs/in.mp4")
        #expect(manifest.name == "in.mp4")
        #expect(manifest.duration == 192)
        #expect(manifest.hasVideo)
        #expect(manifest.engine == "sidon")
        #expect(manifest.generative)
        #expect(manifest.music)
        #expect(manifest.sampleRate == 48_000)
        #expect(manifest.outputs == .init(wav: "/abs/in-enhanced.wav", video: "/abs/in-enhanced.mp4"))
        #expect(manifest.mix == .standard)
        #expect(manifest.settings == .init(linear: false, level: false, loudness: .auto, crf: nil, audioOnly: false))
        #expect(manifest.previewGain == 1.83)
        #expect(manifest.bars.clean.count == 56)
        #expect(manifest.bars.music?.first == 0.2)
        #expect(manifest.curve == .standard)
    }

    @Test func toleratesMissingOptionalFields() throws {
        let json = """
        {"outputs":{"wav":"/a.wav"},"bars":{"clean":[1],"vocals":[1],"background":[0],"original":[1]},
         "settings":{"linear":true,"loudness":-16,"crf":18.0}}
        """
        let manifest = try StemsManifest.decode(Data(json.utf8))
        #expect(manifest.outputs.video == nil)
        #expect(manifest.bars.music == nil)
        #expect(manifest.mix == .standard)
        #expect(manifest.sampleRate == 48_000)
        #expect(manifest.settings.loudness == .lufs(-16))
        #expect(manifest.settings.crf == 18)
        #expect(manifest.curve == .linear)
    }

    @Test func requiresOutputsAndBars() {
        #expect(throws: (any Error).self) {
            try StemsManifest.decode(Data(#"{"bars":{"clean":[],"vocals":[],"background":[],"original":[]}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try StemsManifest.decode(Data(#"{"outputs":{"wav":"/a.wav"}}"#.utf8))
        }
    }

    @Test func roundTripsThroughJSON() throws {
        var manifest = try StemsManifest.decode(Data(Self.specJSON.utf8))
        manifest.settings.loudness = .lufs(-14.5)
        manifest.mix = Mix(speech: 70, background: 20, music: 0)
        let data = try manifest.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""has_video":true"#))
        #expect(text.contains(#""preview_gain":1.83"#))
        #expect(text.contains(#""audio_only":false"#))
        #expect(try StemsManifest.decode(data) == manifest)
    }

    @Test func loadsFromADirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("booth-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(Self.specJSON.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        #expect(try StemsManifest.load(from: directory).name == "in.mp4")
    }

    @Test func previewStemFileNames() {
        let directory = URL(fileURLWithPath: "/tmp/job", isDirectory: true)
        #expect(PreviewStem.allCases.map(\.fileName) == [
            "preview_clean.wav", "preview_vocals.wav", "preview_background.wav", "preview_music.wav", "preview_original.wav",
        ])
        #expect(PreviewStem.music.url(in: directory).path == "/tmp/job/preview_music.wav")
    }
}
