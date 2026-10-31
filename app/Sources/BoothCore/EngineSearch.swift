import Foundation

/// A place the engine executable might be, and why it is looked at.
public struct EngineCandidate: Equatable, Sendable {
    public enum Source: String, Sendable {
        case launchArgument = "--engine"
        case storedPreference = "enginePath preference"
        case environment = "BOOTH_ENGINE"
        case infoPlist = "Info.plist BoothEnginePath"
        case managedInstall = "managed install"
        case userLocalBin = "~/.local/bin"
        case loginShell = "login shell PATH"
    }

    public var path: String
    public var source: Source

    public init(path: String, source: Source) {
        self.path = path
        self.source = source
    }
}

/// Where Booth looks for the engine, in the SPEC §2.3 order. Each candidate is still validated
/// with `app-info` by the caller; this only decides the order.
public enum EngineSearch {
    public static let environmentKey = "BOOTH_ENGINE"
    public static let infoPlistKey = "BoothEnginePath"
    public static let executableName = "booth"

    /// `~/Library/Application Support/Booth/engine`: the engine first-run setup installs.
    public static func managedEngineDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Booth/engine", isDirectory: true)
    }

    /// The managed install's virtual environment, created by `uv sync`.
    public static func managedEnvironment(home: URL) -> URL {
        managedEngineDirectory(home: home).appendingPathComponent(".venv", isDirectory: true)
    }

    public static func managedExecutable(home: URL) -> URL {
        managedEnvironment(home: home).appendingPathComponent("bin/\(executableName)")
    }

    /// The engine version the managed install's last successful `uv sync` was for. Booth and
    /// the `booth` command both write it: empty before an install changes anything, then the
    /// bundled engine's version once `uv sync` succeeds. So a failed or interrupted install is
    /// redone. It lives beside `.venv`, not in it, so a sync that recreates `.venv` can't drop it.
    public static func managedVersionStamp(home: URL) -> URL {
        managedEngineDirectory(home: home).appendingPathComponent(".booth-engine-version")
    }

    /// The `__version__ = "…"` line of an engine's `src/booth/__init__.py`.
    public static func engineVersion(initFile text: String) -> String? {
        let prefix = "__version__ = \""
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.hasSuffix("\""), line.count > prefix.count + 1 else { continue }
            return String(line.dropFirst(prefix.count).dropLast())
        }
        return nil
    }

    /// Whether the managed install matches the engine bundled with Booth: its stamp names that
    /// version. An install from before stamps existed has none, and counts as current when its
    /// own source has that version.
    public static func managedInstallIsCurrent(stamp: String?, installedVersion: String?, bundledVersion: String) -> Bool {
        if let stamp { return stamp.trimmingCharacters(in: .whitespacesAndNewlines) == bundledVersion }
        return installedVersion == bundledVersion
    }

    /// Whether `path` is `directory` or inside it. Both should already have symlinks resolved.
    public static func isInside(_ path: String, directory: String) -> Bool {
        let folder = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// Every candidate known without asking a shell, in order, without duplicates or blanks.
    /// The login shell's `command -v booth` comes last and is the caller's job, because it
    /// costs a process launch.
    public static func candidates(
        launchArgument: String?,
        storedPreference: String?,
        environment: [String: String],
        infoPlistPath: String?,
        home: URL
    ) -> [EngineCandidate] {
        let ordered: [(String?, EngineCandidate.Source)] = [
            (launchArgument, .launchArgument),
            (storedPreference, .storedPreference),
            (environment[environmentKey], .environment),
            (infoPlistPath, .infoPlist),
            (managedExecutable(home: home).path, .managedInstall),
            (home.appendingPathComponent(".local/bin/\(executableName)").path, .userLocalBin),
        ]
        var seen = Set<String>()
        var result: [EngineCandidate] = []
        for (raw, source) in ordered {
            guard let path = normalized(raw, home: home), seen.insert(path).inserted else { continue }
            result.append(EngineCandidate(path: path, source: source))
        }
        return result
    }

    /// Expands `~`, drops blanks and relative paths (a GUI app has no meaningful cwd).
    static func normalized(_ raw: String?, home: URL) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        var path = trimmed
        if path == "~" {
            path = home.path
        } else if path.hasPrefix("~/") {
            path = home.path + path.dropFirst()
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The last absolute path a shell printed for `command -v <tool>`. Login shells can print
    /// banners and warnings first, so only a final line that looks like a path counts.
    public static func pathFromShellOutput(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }
}
