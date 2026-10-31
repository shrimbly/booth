import Foundation
import Testing
@testable import BoothCore

@Suite("Output naming")
struct OutputNamingTests {
    let folder = URL(fileURLWithPath: "/Users/me/Movies", isDirectory: true)

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    @Test func audioBecomesWav() {
        #expect(OutputNaming.outputURL(for: file("voice-memo.m4a")) { _ in false }.path == "/Users/me/Movies/voice-memo-enhanced.wav")
        #expect(OutputNaming.outputURL(for: file("take.wav")) { _ in false }.lastPathComponent == "take-enhanced.wav")
    }

    @Test func videoKeepsItsContainer() {
        #expect(OutputNaming.outputURL(for: file("interview take3.MOV")) { _ in false }.lastPathComponent == "interview take3-enhanced.MOV")
        #expect(OutputNaming.outputURL(for: file("a.mkv")) { _ in false }.lastPathComponent == "a-enhanced.mkv")
    }

    @Test(arguments: ["au", "snd", "ac3", "eac3", "mp2", "m4r", "w64", "AU", "M4R"])
    func engineVerifiedAudioTypesAreAudio(ext: String) {
        #expect(OutputNaming.mediaKind(of: file("clip.\(ext)")) == .audio)
        #expect(OutputNaming.isSupported(file("clip.\(ext)")))
        #expect(OutputNaming.outputURL(for: file("clip.\(ext)")) { _ in false }.lastPathComponent == "clip-enhanced.wav")
    }

    @Test(arguments: ["3g2", "f4v", "qt", "QT"])
    func engineVerifiedVideoTypesKeepTheirContainer(ext: String) {
        #expect(OutputNaming.mediaKind(of: file("clip.\(ext)")) == .video)
        #expect(OutputNaming.outputURL(for: file("clip.\(ext)")) { _ in false }.lastPathComponent == "clip-enhanced.\(ext)")
    }

    @Test func unverifiedTypesStayOut() {
        // None of these was verified with the real engine.
        for ext in ["amr", "ogv", "vob", "mxf", "dv", "m2v", "mod", "pdf", "txt"] {
            #expect(OutputNaming.mediaKind(of: file("clip.\(ext)")) == nil, "\(ext)")
        }
    }

    @Test func supportedExtensionsListEveryTypeOnce() {
        let all = OutputNaming.supportedExtensions
        #expect(all == all.sorted())
        #expect(all.allSatisfy { $0 == $0.lowercased() })
        #expect(Set(all) == OutputNaming.audioExtensions.union(OutputNaming.videoExtensions))
        #expect(Set(all).count == all.count)
        #expect(all.contains("m4r") && all.contains("f4v") && all.contains("wav"))
    }

    @Test func audioOnlyVideoBecomesWav() {
        #expect(OutputNaming.outputURL(for: file("a.mp4"), keepVideo: false) { _ in false }.lastPathComponent == "a-enhanced.wav")
    }

    @Test func collisionsCountUp() {
        let taken: Set<String> = ["voice-memo-enhanced.wav", "voice-memo-enhanced 2.wav"]
        let output = OutputNaming.outputURL(for: file("voice-memo.m4a")) { taken.contains($0.lastPathComponent) }
        #expect(output.lastPathComponent == "voice-memo-enhanced 3.wav")
    }

    @Test func videoAlsoClaimsTheMatchingWav() {
        // The engine writes <name>.wav next to <name>.mp4, so a stray wav must not be overwritten.
        let output = OutputNaming.outputURL(for: file("a.mp4")) { $0.lastPathComponent == "a-enhanced.wav" }
        #expect(output.lastPathComponent == "a-enhanced 2.mp4")
    }

    @Test func dotsInNamesSurvive() {
        #expect(OutputNaming.outputURL(for: file("ep.12.final.mp3")) { _ in false }.lastPathComponent == "ep.12.final-enhanced.wav")
    }

    @Test func checksTheRealFileSystemByDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("booth-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("x-enhanced.wav").path, contents: Data())
        #expect(OutputNaming.outputURL(for: directory.appendingPathComponent("x.wav")).lastPathComponent == "x-enhanced 2.wav")
    }

    @Test func supportedFiles() {
        #expect(OutputNaming.isSupported(file("a.WAV")))
        #expect(OutputNaming.isSupported(file("b.mov")))
        #expect(OutputNaming.mediaKind(of: file("b.mov")) == .video)
        #expect(OutputNaming.mediaKind(of: file("c.flac")) == .audio)
        #expect(!OutputNaming.isSupported(file("notes.txt")))
        #expect(!OutputNaming.isSupported(file("README")))
        #expect(!OutputNaming.isSupported(URL(fileURLWithPath: "/Users/me/Clips.mov/", isDirectory: true)))
        #expect(!OutputNaming.isSupported(URL(string: "https://example.com/a.mp3")!))
        #expect(OutputNaming.audioExtensions.isDisjoint(with: OutputNaming.videoExtensions))
    }

    @Test func partitionKeepsOrder() {
        let urls = [file("a.txt"), file("b.mp4"), file("c.pdf"), file("d.m4a")]
        let (supported, rejected) = OutputNaming.partition(urls)
        #expect(supported.map(\.lastPathComponent) == ["b.mp4", "d.m4a"])
        #expect(rejected.map(\.lastPathComponent) == ["a.txt", "c.pdf"])
    }
}
