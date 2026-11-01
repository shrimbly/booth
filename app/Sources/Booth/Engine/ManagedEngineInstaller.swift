import BoothCore
import Foundation

/// Creates the managed engine in `~/Library/Application Support/Booth/engine` (SPEC §2.3):
/// copies the engine source bundled in `Booth.app/Contents/Resources/engine`, then runs
/// `uv sync --frozen --python 3.11` there. Progress is how much `.venv` has grown, because uv
/// has no machine-readable progress. The same steps update an install that is older than the
/// bundled engine; the version stamp (`EngineSearch.managedVersionStamp`) says which it is.
@MainActor
final class ManagedEngineInstaller {
    /// What the bundled engine folder holds (SPEC §4 step 4). `BUILD` is written by build-app.sh.
    nonisolated static let sourceItems = ["src", "pyproject.toml", "uv.lock", "README.md", buildFile]
    /// `<version>+<hash of the engine's files>`, so a rebuilt engine at the same version still
    /// counts as newer than the install.
    nonisolated static let buildFile = "BUILD"
    static let pollInterval: TimeInterval = 0.5

    private let toolchain: EngineToolchain
    private let source: URL?
    let destination: URL

    init(toolchain: EngineToolchain, source: URL? = ManagedEngineInstaller.bundledSource()) {
        self.toolchain = toolchain
        self.source = source
        self.destination = EngineSearch.managedEngineDirectory(home: toolchain.home)
    }

    var executable: URL { EngineSearch.managedExecutable(home: toolchain.home) }
    private var environmentDirectory: URL { EngineSearch.managedEnvironment(home: toolchain.home) }
    private var stamp: URL { EngineSearch.managedVersionStamp(home: toolchain.home) }

    /// `Contents/Resources/engine` in the app; in a debug build run unbundled, the repository the
    /// app was built from (it holds the same files).
    nonisolated static func bundledSource() -> URL? {
        if let bundled = AppResources.url("engine"), isEngineSource(bundled) { return bundled }
        guard let repository = AppResources.sourceTreeDirectory?
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
        else { return nil }
        return isEngineSource(repository) ? repository : nil
    }

    /// The engine build in a source folder: its `BUILD` line when the build wrote one, otherwise
    /// the version in `src/booth/__init__.py`. Nil if neither is readable.
    nonisolated static func version(ofSource directory: URL) -> String? {
        let build = try? String(contentsOf: directory.appendingPathComponent(buildFile), encoding: .utf8)
        if let build = build?.trimmingCharacters(in: .whitespacesAndNewlines), !build.isEmpty { return build }
        let file = directory.appendingPathComponent("src/booth/__init__.py")
        return (try? String(contentsOf: file, encoding: .utf8)).flatMap(EngineSearch.engineVersion(initFile:))
    }

    /// Whether the managed install in `home` matches the engine in `source`. Always true when
    /// there is no bundled engine to compare with.
    nonisolated static func isCurrent(home: URL, source: URL?) -> Bool {
        guard let wanted = source.flatMap(version(ofSource:)) else { return true }
        let stamp = try? String(contentsOf: EngineSearch.managedVersionStamp(home: home), encoding: .utf8)
        let installed = version(ofSource: EngineSearch.managedEngineDirectory(home: home))
        return EngineSearch.managedInstallIsCurrent(stamp: stamp, installedVersion: installed, bundledVersion: wanted)
    }

    private nonisolated static func isEngineSource(_ directory: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appendingPathComponent("pyproject.toml").path)
            && manager.fileExists(atPath: directory.appendingPathComponent("uv.lock").path)
            && manager.fileExists(atPath: directory.appendingPathComponent("src/booth").path)
    }

    /// Installs and returns the engine executable. `progress` receives the bytes `.venv` grew
    /// by and the seconds since uv started. Throws a `JobError` (`setup_failed`).
    func install(progress: @escaping @MainActor (_ bytesInstalled: Int64, _ elapsed: TimeInterval) -> Void) async throws -> URL {
        guard let source else {
            throw JobError(code: .setupFailed, message: "Booth's engine files are missing from the app. Download Booth again and retry.")
        }
        await toolchain.prepare()
        guard let uv = toolchain.uv else {
            throw JobError(code: .setupFailed, message: "Booth needs uv to install its engine. Install it with “brew install uv”, then try again.")
        }

        Log.info("managed install: copying \(source.path) → \(destination.path)")
        try await copySource(from: source)

        let baseline = await Self.allocatedSize(of: environmentDirectory)
        let started = Date()
        let poller = Task { @MainActor [environmentDirectory] in
            // uv swaps temporary files in and out; report the high-water mark so the bar never
            // moves backwards.
            var grown: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { return }
                let size = await Self.allocatedSize(of: environmentDirectory)
                grown = max(grown, size - baseline)
                progress(grown, Date().timeIntervalSince(started))
            }
        }
        defer { poller.cancel() }

        let sync = EngineProcess(
            executable: uv, arguments: ["sync", "--frozen", "--python", "3.11"], workingDirectory: destination,
            environment: toolchain.environment, label: "uv sync")
        let exit: EngineProcess.Exit
        do {
            exit = try await sync.runToCompletion().exit
        } catch {
            throw JobError(code: .setupFailed, message: "Booth couldn't run uv: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        guard exit.succeeded else {
            let reason = exit.stderrTail.lastMeaningfulLine ?? "uv exited with status \(exit.status)"
            throw JobError(code: .setupFailed, message: "Installing the engine failed: \(reason)")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw JobError(code: .setupFailed, message: "Installing the engine failed: \(executable.lastPathComponent) is missing after uv sync.")
        }
        let version = Self.version(ofSource: source) ?? ""
        do {
            try Data((version + "\n").utf8).write(to: stamp, options: .atomic)
        } catch {
            throw JobError(code: .setupFailed, message: "Booth couldn't finish installing its engine: \(error.localizedDescription)")
        }
        Log.info("managed install: ready at \(executable.path) (engine \(version))")
        removeLeftovers()
        return executable
    }

    /// What earlier engines kept beside the managed install and this one doesn't use: Sidon's own
    /// Python environment (about 850 MB) and its install lock (the engine's `tools.LEFTOVERS`).
    /// Removed in the background once this engine is installed, as `booth setup` does.
    private func removeLeftovers() {
        let cache = toolchain.home.appendingPathComponent(".cache/booth", isDirectory: true)
        let leftovers = ["sidon-venv", "sidon-venv.lock"].map { cache.appendingPathComponent($0) }
        Task.detached(priority: .background) {
            for url in leftovers where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    Log.info("managed install: removed \(url.path), which this engine doesn't use")
                } catch {
                    Log.error("managed install: couldn't remove \(url.path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private

    /// Replaces the source files, keeping an existing `.venv` so a re-install only syncs the
    /// difference. The stamp is emptied first: until `uv sync` succeeds, the install isn't current.
    private func copySource(from source: URL) async throws {
        let destination = destination
        let stamp = stamp
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data().write(to: stamp)
                for item in Self.sourceItems {
                    let from = source.appendingPathComponent(item)
                    guard manager.fileExists(atPath: from.path) else { continue }
                    let to = destination.appendingPathComponent(item)
                    if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
                    try manager.copyItem(at: from, to: to)
                }
            } catch {
                throw JobError(code: .setupFailed, message: "Booth couldn't copy its engine: \(error.localizedDescription)")
            }
        }.value
    }

    /// Allocated bytes under `directory` (0 when it does not exist), measured off the main thread.
    nonisolated static func allocatedSize(of directory: URL) async -> Int64 {
        await Task.detached(priority: .utility) { measureAllocatedSize(of: directory) }.value
    }

    private nonisolated static func measureAllocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
