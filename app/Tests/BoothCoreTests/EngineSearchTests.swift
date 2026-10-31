import Foundation
import Testing
@testable import BoothCore

@Suite("Engine search")
struct EngineSearchTests {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    @Test func followsTheSpecOrder() {
        let candidates = EngineSearch.candidates(
            launchArgument: "/opt/flag/booth",
            storedPreference: "/opt/pref/booth",
            environment: ["BOOTH_ENGINE": "/opt/env/booth"],
            infoPlistPath: "/repo/.venv/bin/booth",
            home: home)
        #expect(candidates.map(\.source) == [.launchArgument, .storedPreference, .environment, .infoPlist, .managedInstall, .userLocalBin])
        #expect(candidates.map(\.path) == [
            "/opt/flag/booth",
            "/opt/pref/booth",
            "/opt/env/booth",
            "/repo/.venv/bin/booth",
            "/Users/me/Library/Application Support/Booth/engine/.venv/bin/booth",
            "/Users/me/.local/bin/booth",
        ])
    }

    @Test func skipsMissingBlankAndRelativeValues() {
        let candidates = EngineSearch.candidates(
            launchArgument: nil, storedPreference: "  ", environment: ["BOOTH_ENGINE": "relative/booth"],
            infoPlistPath: "", home: home)
        #expect(candidates.map(\.source) == [.managedInstall, .userLocalBin])
    }

    @Test func expandsTildeAndDropsDuplicates() {
        let candidates = EngineSearch.candidates(
            launchArgument: "~/.local/bin/booth", storedPreference: "/Users/me/.local/bin/../bin/booth",
            environment: [:], infoPlistPath: nil, home: home)
        // The preference resolves to the same file as the flag, and so does ~/.local/bin.
        #expect(candidates == [
            EngineCandidate(path: "/Users/me/.local/bin/booth", source: .launchArgument),
            EngineCandidate(path: "/Users/me/Library/Application Support/Booth/engine/.venv/bin/booth", source: .managedInstall),
        ])
    }

    @Test func managedInstallPaths() {
        #expect(EngineSearch.managedEngineDirectory(home: home).path == "/Users/me/Library/Application Support/Booth/engine")
        #expect(EngineSearch.managedExecutable(home: home).path == "/Users/me/Library/Application Support/Booth/engine/.venv/bin/booth")
    }

    @Test func readsThePathALoginShellPrints() {
        #expect(EngineSearch.pathFromShellOutput("/Users/me/.local/bin/booth\n") == "/Users/me/.local/bin/booth")
        #expect(EngineSearch.pathFromShellOutput("Welcome back!\nconda activated\n/opt/homebrew/bin/uv\n") == "/opt/homebrew/bin/uv")
        #expect(EngineSearch.pathFromShellOutput("") == nil)
        #expect(EngineSearch.pathFromShellOutput("uv: aliased to uvx\n") == nil)
    }

    @Test func managedVersionStampSitsBesideTheEnvironment() {
        #expect(EngineSearch.managedVersionStamp(home: home).path == "/Users/me/Library/Application Support/Booth/engine/.booth-engine-version")
    }

    @Test func readsTheEngineVersion() {
        #expect(EngineSearch.engineVersion(initFile: "\"\"\"booth.\"\"\"\n\n__version__ = \"0.2.0\"\n") == "0.2.0")
        #expect(EngineSearch.engineVersion(initFile: "VERSION = 1\n") == nil)
        #expect(EngineSearch.engineVersion(initFile: "__version__ = \"\"\n") == nil)
    }

    @Test func aManagedInstallIsCurrentWhenItsStampMatches() {
        #expect(EngineSearch.managedInstallIsCurrent(stamp: "0.2.0\n", installedVersion: "0.2.0", bundledVersion: "0.2.0"))
        // Upgraded Booth: the install is older.
        #expect(!EngineSearch.managedInstallIsCurrent(stamp: "0.1.0\n", installedVersion: "0.1.0", bundledVersion: "0.2.0"))
        // An update that failed after copying the new source: the stamp was emptied first.
        #expect(!EngineSearch.managedInstallIsCurrent(stamp: "", installedVersion: "0.2.0", bundledVersion: "0.2.0"))
        // A failed downgrade can't pass for current by its stamp either.
        #expect(!EngineSearch.managedInstallIsCurrent(stamp: "", installedVersion: "0.1.0", bundledVersion: "0.2.0"))
    }

    @Test func anInstallFromBeforeStampsGoesByItsSource() {
        #expect(EngineSearch.managedInstallIsCurrent(stamp: nil, installedVersion: "0.2.0", bundledVersion: "0.2.0"))
        #expect(!EngineSearch.managedInstallIsCurrent(stamp: nil, installedVersion: "0.1.0", bundledVersion: "0.2.0"))
        #expect(!EngineSearch.managedInstallIsCurrent(stamp: nil, installedVersion: nil, bundledVersion: "0.2.0"))
    }

    @Test func tellsWhetherAPathIsInsideAFolder() {
        let bundle = "/Applications/Booth.app"
        #expect(EngineSearch.isInside("/Applications/Booth.app/Contents/Resources/bin/booth", directory: bundle))
        #expect(EngineSearch.isInside("/Applications/Booth.app/Contents/Resources/bin/booth", directory: bundle + "/"))
        #expect(!EngineSearch.isInside("/Applications/Booth.app.old/booth", directory: bundle))
        #expect(!EngineSearch.isInside("/opt/homebrew/bin/booth", directory: bundle))
    }
}

@Suite("Engine environment")
struct EngineEnvironmentTests {
    func make(_ base: [String: String], uv: String? = nil, extra: [String] = [], existing: Set<String>? = nil) -> [String: String] {
        EngineEnvironment.make(base: base, home: "/Users/me", uv: uv, extraDirectories: extra) { existing?.contains($0) ?? true }
    }

    @Test func extendsAFinderLaunchedPath() {
        let environment = make(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin:/Users/me/.cargo/bin")
    }

    @Test func keepsExistingOrderAndOnlyAddsDirectoriesThatExist() {
        let environment = make(["PATH": "/usr/local/bin:/usr/bin"], existing: ["/opt/homebrew/bin", "/usr/local/bin"])
        #expect(environment["PATH"] == "/usr/local/bin:/usr/bin:/opt/homebrew/bin")
    }

    @Test func fallsBackWhenPathIsMissing() {
        let environment = make([:], existing: [])
        #expect(environment["PATH"] == EngineEnvironment.fallbackPath)
    }

    @Test func pointsTheEngineAtTheUvBoothFound() {
        let environment = make(["PATH": "/usr/bin"], uv: "/opt/conda/bin/uv", existing: ["/opt/conda/bin"])
        #expect(environment["BOOTH_ENGINE_UV"] == "/opt/conda/bin/uv")
        #expect(environment["PATH"] == "/usr/bin:/opt/conda/bin")
    }

    @Test func addsFoldersTheLoginShellKnew() {
        let environment = make(["PATH": "/usr/bin"], extra: ["/opt/local/bin"], existing: ["/opt/local/bin"])
        #expect(environment["PATH"] == "/usr/bin:/opt/local/bin")
    }

    @Test func toolDirectoriesCanBeReplaced() {
        let environment = EngineEnvironment.make(
            base: ["PATH": "/usr/bin"], home: "/Users/me", uv: nil, toolDirectories: ["/tools"]) { _ in true }
        #expect(environment["PATH"] == "/usr/bin:/tools")
    }

    @Test func tellsTheShimNotToInstall() {
        #expect(make(["PATH": "/usr/bin"])["BOOTH_NO_INSTALL"] == "1")
    }

    @Test func findsMissingTools() {
        let executables: Set = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffprobe"]
        let missing = { (path: String) in
            EngineEnvironment.missingTools(EngineEnvironment.mediaTools, path: path) { executables.contains($0) }
        }
        #expect(missing("/usr/bin:/opt/homebrew/bin:/usr/local/bin") == [])
        #expect(missing("/usr/bin:/opt/homebrew/bin") == ["ffprobe"])
        #expect(missing("/usr/bin:/bin") == ["ffmpeg", "ffprobe"])
        #expect(missing("") == ["ffmpeg", "ffprobe"])
    }

    @Test func isolatesThePythonEnvironment() {
        let environment = make(["PATH": "/usr/bin", "PYTHONPATH": "/x", "PYTHONHOME": "/y", "VIRTUAL_ENV": "/z", "HOME": "/Users/me"])
        #expect(environment["PYTHONPATH"] == nil && environment["PYTHONHOME"] == nil && environment["VIRTUAL_ENV"] == nil)
        #expect(environment["PYTHONUNBUFFERED"] == "1")
        #expect(environment["HOME"] == "/Users/me")
    }
}
