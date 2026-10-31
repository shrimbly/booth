import Foundation
import Testing
@testable import BoothCore

@Suite("Launch options")
struct LaunchOptionsTests {
    func parse(_ arguments: [String]) -> LaunchOptions {
        LaunchOptions.parse(arguments, currentDirectory: "/Users/me/work")
    }

    @Test func defaults() {
        let options = parse([])
        #expect(options == LaunchOptions())
        #expect(!options.isHeadless)
        #expect(options.selfTestEngineName == "sidon")
    }

    @Test func flags() {
        let options = parse(["--demo", "--open", "--reset-defaults", "--motion-probe"])
        #expect(options.demo && options.openAtLaunch && options.resetDefaults && options.motionProbe)
        #expect(!options.isHeadless)
        #expect(options.problems.isEmpty && options.unrecognized.isEmpty)
    }

    @Test func enqueueTakesPathsUntilTheNextFlag() {
        let options = parse(["--enqueue", "/a/one.wav", "two.mp4", "~/three.m4a", "--demo"])
        #expect(options.enqueue.map(\.path) == [
            "/a/one.wav",
            "/Users/me/work/two.mp4",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("three.m4a").path,
        ])
        #expect(options.demo)
    }

    @Test func enginePathResolvesRelativePaths() {
        #expect(parse(["--engine", "../booth/.venv/bin/booth"]).enginePath == "/Users/me/booth/.venv/bin/booth")
        #expect(parse(["--engine=/opt/sv"]).enginePath == "/opt/sv")
    }

    @Test func headlessModes() {
        let states = parse(["--render-states", "out/states"])
        #expect(states.renderStatesDirectory?.path == "/Users/me/work/out/states")
        #expect(states.renderStatesDirectory?.hasDirectoryPath == true)
        #expect(states.isHeadless)

        #expect(parse(["--render-glyphs", "/tmp/g"]).renderGlyphsDirectory?.path == "/tmp/g")

        let demo = parse(["--render-demo", "site/frames"])
        #expect(demo.renderDemoDirectory?.path == "/Users/me/work/site/frames")
        #expect(demo.isHeadless)

        let selfTest = parse(["--selftest-engine", "clip.wav", "--selftest-engine-name", "df3", "--engine", "/e/sv"])
        #expect(selfTest.selfTestInput?.path == "/Users/me/work/clip.wav")
        #expect(selfTest.selfTestEngineName == "df3")
        #expect(selfTest.enginePath == "/e/sv")
        #expect(selfTest.isHeadless)
    }

    @Test func rejectsUnknownEngineNames() {
        let options = parse(["--selftest-engine", "a.wav", "--selftest-engine-name", "studio"])
        #expect(options.selfTestEngineName == "sidon")
        #expect(options.problems.count == 1)
    }

    @Test func missingValuesAreReported() {
        let options = parse(["--engine", "--demo", "--render-states"])
        #expect(options.enginePath == nil)
        #expect(options.renderStatesDirectory == nil)
        #expect(options.demo)
        #expect(options.problems == ["--engine needs a value", "--render-states needs a value"])
        #expect(parse(["--enqueue"]).problems == ["--enqueue needs at least one path"])
    }

    @Test func systemArgumentsAreIgnored() {
        let options = parse(["-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES", "--demo", "--frobnicate"])
        #expect(options.demo)
        #expect(options.unrecognized == ["-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES", "--frobnicate"])
        #expect(options.problems.isEmpty)
    }
}
