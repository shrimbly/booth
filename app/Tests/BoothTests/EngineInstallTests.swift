import BoothCore
import Foundation
import Testing
@testable import Booth

/// A scratch home with an engine source "bundled with Booth", ffmpeg and ffprobe stand-ins, and
/// a fake uv whose `sync` installs a script engine into the managed install's `.venv`.
@MainActor
final class ManagedEngineFixture {
    let home: URL
    let source: URL
    let tools: URL
    let uv: URL
    let toolchain: EngineToolchain
    private(set) var locator: EngineLocator!

    init(bundledVersion: String = "0.2.0", ffmpeg: Bool = true) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("booth-managed-tests-\(UUID().uuidString)", isDirectory: true)
        source = home.appendingPathComponent("bundled-engine", isDirectory: true)
        tools = home.appendingPathComponent("tools", isDirectory: true)
        uv = tools.appendingPathComponent("uv")
        try Self.writeSource(version: bundledVersion, at: source)
        if ffmpeg {
            for tool in EngineEnvironment.mediaTools {
                try ScriptEngine.install("#!/bin/sh\nexit 0\n", at: tools.appendingPathComponent(tool))
            }
        }
        let engineScript = home.appendingPathComponent("engine-script")
        try ScriptEngine.install(ScriptEngine.script(), at: engineScript)
        try ScriptEngine.install("""
            #!/bin/sh
            echo "$*" >> '\(home.path)/uv.log'
            if [ -f '\(home.path)/uv-fails' ]; then echo 'error: network down' >&2; exit 2; fi
            mkdir -p .venv/bin
            cp '\(engineScript.path)' .venv/bin/booth
            """, at: uv)
        toolchain = EngineToolchain(
            home: home,
            baseEnvironment: ["PATH": "/usr/bin:/bin:\(tools.path)", "SHELL": "/usr/bin/false", EngineEnvironment.uvKey: uv.path],
            toolDirectories: [])
        locator = makeLocator()
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    static func writeSource(version: String, at directory: URL) throws {
        let package = directory.appendingPathComponent("src/booth", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "\"\"\"booth.\"\"\"\n\n__version__ = \"\(version)\"\n"
            .write(to: package.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        for file in ["pyproject.toml", "uv.lock", "README.md"] {
            try Data().write(to: directory.appendingPathComponent(file))
        }
    }

    /// A fresh search, as at the next launch.
    func makeLocator(source: URL?? = nil) -> EngineLocator {
        EngineLocator(
            toolchain: toolchain, launchArgument: nil, storedPreference: { nil }, environment: [:], infoPlistPath: nil,
            bundledEngineSource: source ?? self.source, ownBundle: nil, validationTimeout: 5, responseTimeout: 30)
    }

    /// An existing managed install of `version`, stamped with `stamp` (nil: from before stamps).
    func installManaged(version: String, stamp: String?) throws {
        let directory = EngineSearch.managedEngineDirectory(home: home)
        try Self.writeSource(version: version, at: directory)
        try ScriptEngine.install(ScriptEngine.script(), at: managedExecutable)
        if let stamp { try (stamp + "\n").write(to: stampFile, atomically: true, encoding: .utf8) }
    }

    var managedExecutable: URL { EngineSearch.managedExecutable(home: home) }
    var stampFile: URL { EngineSearch.managedVersionStamp(home: home) }
    var stamp: String? { try? String(contentsOf: stampFile, encoding: .utf8) }
    var installedVersion: String? { ManagedEngineInstaller.version(ofSource: EngineSearch.managedEngineDirectory(home: home)) }

    /// What the managed engine was asked to do, in order.
    var managedCalls: [String] { lines(managedExecutable.deletingLastPathComponent().appendingPathComponent("calls.log")) }
    var uvCalls: [String] { lines(home.appendingPathComponent("uv.log")) }

    func uvFails(_ fails: Bool) throws {
        let marker = home.appendingPathComponent("uv-fails")
        if fails { try Data().write(to: marker) } else { try FileManager.default.removeItem(at: marker) }
    }

    /// First-run setup on this fixture's locator, to its end.
    func runSetup() async -> EventRecorder {
        let runner = SetupRunner(locator: locator, installer: ManagedEngineInstaller(toolchain: toolchain, source: source))
        let recorder = EventRecorder()
        runner.start { recorder.record($0) }
        await waitFor(20) { !recorder.terminal.isEmpty }
        return recorder
    }

    private func lines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

extension EventRecorder {
    var installed: Bool {
        events.contains { event in
            if case .setup(let progress) = event { return progress.phase == SetupProgressCombiner.installPhase }
            return false
        }
    }
}

@Suite("Managed engine updates", .serialized)
@MainActor
struct ManagedEngineUpdateTests {
    /// A rebuilt engine keeps its version number; its BUILD line still tells the two apart.
    @Test(.enabled(if: EngineToolchainTests.noBundledUV))
    func aRebuiltEngineAtTheSameVersionIsUpdated() async throws {
        let fixture = try ManagedEngineFixture(bundledVersion: "0.1.0")
        let source = fixture.source
        try "0.1.0+bbbbbbbbbbbb\n".write(to: source.appendingPathComponent(ManagedEngineInstaller.buildFile), atomically: true, encoding: .utf8)
        try fixture.installManaged(version: "0.1.0", stamp: "0.1.0+aaaaaaaaaaaa")
        #expect(await fixture.locator.locate() == .needsSetup(nil))
        #expect(fixture.locator.managedInstallNeedsUpdate)

        let recorder = await fixture.runSetup()
        #expect(recorder.terminal == [.done(EngineDone())])
        #expect(fixture.stamp == "0.1.0+bbbbbbbbbbbb\n")
        #expect(fixture.installedVersion == "0.1.0+bbbbbbbbbbbb")
    }

    @Test(.enabled(if: EngineToolchainTests.noBundledUV))
    func anOlderManagedInstallIsUpdatedWithProgress() async throws {
        let fixture = try ManagedEngineFixture(bundledVersion: "0.2.0")
        try fixture.installManaged(version: "0.1.0", stamp: "0.1.0")
        #expect(await fixture.locator.locate() == .needsSetup(nil))
        #expect(fixture.locator.managedInstallNeedsUpdate)
        #expect(fixture.managedCalls.isEmpty) // the old engine isn't run

        let recorder = await fixture.runSetup()
        #expect(recorder.terminal == [.done(EngineDone())])
        #expect(recorder.installed)
        #expect(fixture.uvCalls == ["sync --frozen --python 3.11"])
        #expect(fixture.stamp == "0.2.0\n")
        #expect(fixture.installedVersion == "0.2.0")
        #expect(!fixture.locator.managedInstallNeedsUpdate)

        guard case .ready(let installation) = await fixture.makeLocator().locate() else {
            Issue.record("expected the updated engine to be ready")
            return
        }
        #expect(installation.executable.path == fixture.managedExecutable.path)
        #expect(fixture.uvCalls.count == 1)
    }

    @Test(.enabled(if: EngineToolchainTests.noBundledUV))
    func aFailedUpdateIsRetried() async throws {
        let fixture = try ManagedEngineFixture(bundledVersion: "0.2.0")
        try fixture.installManaged(version: "0.1.0", stamp: "0.1.0")
        try fixture.uvFails(true)
        _ = await fixture.locator.locate()
        let failed = await fixture.runSetup()
        #expect(failed.terminal == [.error(JobError(code: .setupFailed, message: "Installing the engine failed: error: network down"))])
        // The new source is over the old environment, and the stamp says so.
        #expect(fixture.installedVersion == "0.2.0")
        #expect(fixture.stamp == "")

        // At the next launch the engine still isn't run as it is.
        let relaunched = fixture.makeLocator()
        #expect(await relaunched.locate() == .needsSetup(nil))
        #expect(relaunched.managedInstallNeedsUpdate)

        // Try again, once the network is back.
        try fixture.uvFails(false)
        let retried = await fixture.runSetup()
        #expect(retried.terminal == [.done(EngineDone())])
        #expect(fixture.stamp == "0.2.0\n")
        #expect(fixture.uvCalls.count == 2)
    }

    @Test func anInstallFromBeforeStampsIsKeptWhenItMatches() async throws {
        let fixture = try ManagedEngineFixture(bundledVersion: "0.2.0")
        try fixture.installManaged(version: "0.2.0", stamp: nil)
        guard case .ready(let installation) = await fixture.locator.locate() else {
            Issue.record("expected the managed engine to be ready")
            return
        }
        #expect(installation.executable.path == fixture.managedExecutable.path)
        #expect(fixture.uvCalls.isEmpty)
    }

    @Test func withoutABundledEngineAnyManagedInstallIsUsed() async throws {
        let fixture = try ManagedEngineFixture(bundledVersion: "0.2.0")
        try fixture.installManaged(version: "0.1.0", stamp: "0.1.0")
        guard case .ready = await fixture.makeLocator(source: .some(nil)).locate() else {
            Issue.record("expected the managed engine to be ready")
            return
        }
    }

    /// The engine's setup downloads ffmpeg with the models, so a Mac without it is set up as usual.
    @Test(.enabled(if: EngineToolchainTests.noBundledUV))
    func withoutFfmpegTheEngineIsStillInstalled() async throws {
        let fixture = try ManagedEngineFixture(ffmpeg: false)
        #expect(await fixture.locator.locate() == .needsSetup(nil))
        let recorder = await fixture.runSetup()
        #expect(recorder.terminal == [.done(EngineDone())])
        #expect(recorder.installed)
        #expect(fixture.uvCalls == ["sync --frozen --python 3.11"])
    }
}

@Suite("Engine search skips Booth's own command", .serialized)
@MainActor
struct OwnCommandTests {
    /// `<scratch>/Booth.app/Contents/Resources/bin/booth`, linked from `<scratch>/bin` the
    /// way Homebrew links it into /opt/homebrew/bin.
    @MainActor
    struct FakeBooth {
        let root: URL
        let app: URL
        let command: URL
        let link: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("booth-own-\(UUID().uuidString)", isDirectory: true)
            app = root.appendingPathComponent("Booth.app", isDirectory: true)
            command = app.appendingPathComponent("Contents/Resources/bin/booth")
            link = root.appendingPathComponent("bin/booth")
            try ScriptEngine.install(ScriptEngine.script(), at: command)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: command)
        }

        var ran: Bool { FileManager.default.fileExists(atPath: command.deletingLastPathComponent().appendingPathComponent("calls.log").path) }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func locator(launchArgument: String?, shell: String) -> EngineLocator {
            let toolchain = EngineToolchain(home: root, baseEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": shell], toolDirectories: [])
            return EngineLocator(
                toolchain: toolchain, launchArgument: launchArgument, storedPreference: { nil }, environment: [:],
                infoPlistPath: nil, bundledEngineSource: nil, ownBundle: app)
        }
    }

    @Test func aLinkToBoothsOwnCommandIsNotRun() async throws {
        let booth = try FakeBooth()
        defer { booth.remove() }
        #expect(await booth.locator(launchArgument: booth.link.path, shell: "/usr/bin/false").locate() == .needsSetup(nil))
        #expect(!booth.ran)
    }

    @Test func theLoginShellFindingBoothsOwnCommandIsNotRun() async throws {
        let booth = try FakeBooth()
        defer { booth.remove() }
        let shell = booth.root.appendingPathComponent("shell")
        try ScriptEngine.install("#!/bin/sh\ncase \"$3\" in *booth) echo '\(booth.link.path)' ;; esac\n", at: shell)
        #expect(await booth.locator(launchArgument: nil, shell: shell.path).locate() == .needsSetup(nil))
        #expect(!booth.ran)
    }

    @Test func theCommandRefusesToInstallForBooth() async throws {
        let shim = try #require(AppResources.sourceTreeDirectory).appendingPathComponent("bin/booth")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("booth-shim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = shim
        process.arguments = ["app-info"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", EngineEnvironment.noInstallKey: "1"]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        #expect(message.contains("BOOTH_NO_INSTALL"))
        #expect(!FileManager.default.fileExists(atPath: EngineSearch.managedEngineDirectory(home: home).path))
    }
}

@Suite("Login shell", .serialized)
@MainActor
struct LoginShellTests {
    func shell(_ script: String) throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("booth-shell-\(UUID().uuidString)", isDirectory: true)
        let shell = directory.appendingPathComponent("shell")
        try ScriptEngine.install("#!/bin/sh\n" + script, at: shell)
        return (shell, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test func aBackgroundJobHoldingTheOutputDoesNotHoldUpTheAnswer() async throws {
        // A real zsh login shell whose profile leaves a job running with the shell's stdout.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("booth-zsh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "sleep 4 &\n".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let started = Date()
        let path = await LoginShell.commandPath(
            "sh", environment: ["SHELL": "/bin/zsh", "HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin"])
        #expect(path == "/bin/sh")
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func aShellThatNeverAnswersIsGivenUpOn() async throws {
        let (shell, remove) = try shell("trap '' TERM\nsleep 4\n")
        defer { remove() }
        let started = Date()
        let path = await LoginShell.commandPath("sh", environment: ["SHELL": shell.path, "PATH": "/usr/bin:/bin"], timeout: 0.5)
        #expect(path == nil)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func ffmpegTheLoginShellKnowsJoinsTheEnginePath() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("booth-ffmpeg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let macPorts = home.appendingPathComponent("opt/local/bin", isDirectory: true)
        for tool in EngineEnvironment.mediaTools {
            try ScriptEngine.install("#!/bin/sh\nexit 0\n", at: macPorts.appendingPathComponent(tool))
        }
        // A login profile that puts that folder on PATH.
        let shell = home.appendingPathComponent("shell")
        try ScriptEngine.install("#!/bin/sh\nPATH='\(macPorts.path)':$PATH\neval \"$3\"\n", at: shell)
        let toolchain = EngineToolchain(home: home, baseEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": shell.path], toolDirectories: [])
        #expect(toolchain.missingMediaTools == EngineEnvironment.mediaTools)
        await toolchain.prepare()
        #expect(toolchain.missingMediaTools.isEmpty)
        #expect(toolchain.environment["PATH"]?.split(separator: ":").contains(Substring(macPorts.path)) == true)
    }
}

@Suite("Setup after an engine that didn't answer", .serialized)
@MainActor
struct SetupRetryTests {
    @Test func tryAgainAsksTheEngineAgain() async throws {
        let engine = try ScriptEngine(appInfoDelay: 30)
        // Long enough for a busy test machine to start the engine for the second probe.
        let locator = engine.locator(validationTimeout: 0.3, responseTimeout: 3)
        #expect(await locator.locate() == .unresponsive(EngineCandidate(path: engine.executable.path, source: .launchArgument)))

        // The user chose Allow: the engine answers now.
        try ScriptEngine.install(ScriptEngine.script(), at: engine.executable)
        let runner = SetupRunner(locator: locator, installer: ManagedEngineInstaller(toolchain: engine.toolchain, source: nil))
        let recorder = EventRecorder()
        runner.start { recorder.record($0) }
        await waitFor(10) { !recorder.terminal.isEmpty }
        #expect(recorder.terminal == [.done(EngineDone())])
        #expect(!recorder.installed)
        #expect(!locator.lastSearchTimedOut)
        #expect(engine.calls == ["app-info", "app-info"])
        #expect(!FileManager.default.fileExists(atPath: EngineSearch.managedEngineDirectory(home: engine.directory).path))
    }
}
