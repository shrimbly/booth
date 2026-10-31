import Foundation

/// The environment every engine process (and `uv`) runs with.
///
/// Apps started from Finder get `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so ffmpeg and uv from
/// Homebrew or `~/.local/bin` would be invisible to the engine and its children.
public enum EngineEnvironment {
    public static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The engine's own override for the uv it uses to bootstrap the Sidon venv.
    public static let uvKey = "BOOTH_ENGINE_UV"

    /// Tells the `booth` command in Booth.app not to install or update the engine. Booth
    /// does that itself, with progress; a probe must never start a 540 MB install.
    public static let noInstallKey = "BOOTH_NO_INSTALL"

    /// The engine reads and writes every file, audio or video, with these.
    public static let mediaTools = ["ffmpeg", "ffprobe"]

    /// Variables that would point the engine's Python at someone else's interpreter or packages.
    public static let strippedKeys = ["PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV", "__PYVENV_LAUNCHER__", "PYTHONSTARTUP"]

    /// Tool directories appended to `PATH` when they exist, after whatever is already there.
    public static func toolDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin"]
    }

    /// `base` with `PATH` extended, unbuffered Python output, and `BOOTH_ENGINE_UV` set when Booth
    /// found a uv (whose directory also joins `PATH`). `toolDirectories` replaces the usual ones
    /// (nil keeps them); `extraDirectories` follow them, such as where the login shell found ffmpeg.
    public static func make(
        base: [String: String],
        home: String,
        uv: String?,
        toolDirectories: [String]? = nil,
        extraDirectories: [String] = [],
        directoryExists: (String) -> Bool
    ) -> [String: String] {
        var environment = base
        for key in strippedKeys { environment[key] = nil }

        let basePath = base["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackPath
        var path = basePath.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        var extras = (toolDirectories ?? Self.toolDirectories(home: home)) + extraDirectories
        if let uv { extras.append((uv as NSString).deletingLastPathComponent) }
        for directory in extras where !path.contains(directory) && directoryExists(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")

        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment[noInstallKey] = "1"
        if let uv { environment[uvKey] = uv }
        return environment
    }

    /// The tools in `names` that no directory of `path` holds, in order.
    public static func missingTools(_ names: [String], path: String, isExecutable: (String) -> Bool) -> [String] {
        let directories = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return names.filter { name in
            !directories.contains { isExecutable(($0 as NSString).appendingPathComponent(name)) }
        }
    }
}
