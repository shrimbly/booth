import BoothCore
import Foundation

/// The environment engine processes run in, the uv that installs and runs engine pieces, and
/// the ffmpeg the engine reads every file with.
///
/// uv is looked for in the copy bundled in `Booth.app/Contents/Resources/bin/uv`, the usual
/// install directories, then the user's login shell (which knows PATH tweaks a Finder-launched
/// app never sees). ffmpeg and ffprobe are looked for on the engine's `PATH`, then through the
/// login shell, whose folder then joins that `PATH`. Only a find is remembered: after "Install
/// uv (or ffmpeg), then try again" the next `prepare()` looks again.
@MainActor
final class EngineToolchain {
    let home: URL
    private let baseEnvironment: [String: String]
    /// The usual install directories, searched for uv after `PATH` and added to the engine's
    /// `PATH`; nil means `EngineEnvironment.toolDirectories`.
    private let toolDirectories: [String]?
    private(set) var uv: URL?
    /// Folders holding ffmpeg or ffprobe that only the login shell knew about.
    private var mediaToolDirectories: [String] = []
    /// The search in progress; concurrent callers share it.
    private var search: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         toolDirectories: [String]? = nil) {
        self.home = home
        self.baseEnvironment = baseEnvironment
        self.toolDirectories = toolDirectories
    }

    /// The process environment for the engine and uv (see `EngineEnvironment`).
    var environment: [String: String] {
        EngineEnvironment.make(
            base: baseEnvironment, home: home.path, uv: uv?.path, toolDirectories: toolDirectories,
            extraDirectories: mediaToolDirectories
        ) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// ffmpeg and ffprobe, if the engine's `PATH` lacks them.
    var missingMediaTools: [String] {
        EngineEnvironment.missingTools(EngineEnvironment.mediaTools, path: environment["PATH"] ?? "") { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// Finds uv and ffmpeg unless they were already found. Cheap once found; while one is
    /// missing, every call searches again (one search at a time).
    func prepare() async {
        guard uv == nil || !missingMediaTools.isEmpty else { return }
        if let search {
            await search.value
            return
        }
        let running = Task { await findMissing() }
        search = running
        await running.value
        search = nil
    }

    private func findMissing() async {
        if uv == nil {
            uv = await findUV()
            Log.info("uv: \(uv?.path ?? "not found")")
        }
        for tool in EngineEnvironment.mediaTools where missingMediaTools.contains(tool) {
            let found = await LoginShell.commandPath(tool, environment: baseEnvironment)
            Log.info("\(tool): \(found.map { "\($0) (login shell)" } ?? "not found")")
            guard let found else { continue }
            let directory = (found as NSString).deletingLastPathComponent
            if !mediaToolDirectories.contains(directory) { mediaToolDirectories.append(directory) }
        }
    }

    private func findUV() async -> URL? {
        if let bundled = AppResources.url("bin/uv"), isExecutable(bundled.path) { return bundled }
        if let explicit = baseEnvironment[EngineEnvironment.uvKey], isExecutable(explicit) {
            return URL(fileURLWithPath: explicit)
        }
        let pathDirectories = (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories + (toolDirectories ?? EngineEnvironment.toolDirectories(home: home.path)) {
            let candidate = (directory as NSString).appendingPathComponent("uv")
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return await LoginShell.commandPath("uv", environment: baseEnvironment).map { URL(fileURLWithPath: $0) }
    }

    private func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Asks the user's login shell where a command is, the way Terminal would find it.
enum LoginShell {
    static let timeout: TimeInterval = 5

    /// `$SHELL -l -c 'command -v <name>'`; nil when the shell does not know it or takes longer
    /// than `timeout`. It never waits longer: the answer is read when the shell exits, not at end
    /// of file, which a background job started by the login profile can hold off indefinitely.
    static func commandPath(_ name: String, environment: [String: String], timeout: TimeInterval = LoginShell.timeout) async -> String? {
        let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(name)"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    Log.error("login shell \(shell): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                let data = outputOnExit(of: process, reading: output.fileHandleForReading, deadline: Date(timeIntervalSinceNow: timeout))
                try? output.fileHandleForReading.close()
                guard let data else {
                    Log.error("login shell \(shell) took longer than \(timeout) s to answer `command -v \(name)`")
                    stop(process)
                    continuation.resume(returning: nil)
                    return
                }
                let path = EngineSearch.pathFromShellOutput(String(decoding: data, as: UTF8.self))
                continuation.resume(returning: path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil })
            }
        }
    }

    /// Everything `process` wrote once it has exited, or nil if it is still running at
    /// `deadline`. Reads as it goes, so a chatty profile can't fill the pipe and stall.
    private static func outputOnExit(of process: Process, reading handle: FileHandle, deadline: Date) -> Data? {
        let descriptor = handle.fileDescriptor
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var atEnd = false
        while true {
            // Checked before reading, so whatever the shell wrote before it exited is read below.
            let exited = !process.isRunning
            var count = 0
            if !atEnd {
                var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let wait = exited ? 0 : Int32(min(100, max(0, deadline.timeIntervalSinceNow * 1000)))
                if poll(&request, 1, wait) > 0 {
                    count = read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        data.append(contentsOf: buffer[0..<count])
                    } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                        atEnd = true
                    }
                }
            } else if !exited {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if count > 0 { continue }
            if exited { return data }
            if Date() >= deadline { return nil }
        }
    }

    /// SIGTERM, then SIGKILL a second later for a shell that ignores it. Nobody waits for it.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
