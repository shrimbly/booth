import Foundation
import os

/// The app log: `~/Library/Logs/Booth/booth.log` (append, rotated to `booth.log.1` at 5 MB),
/// mirrored to the unified log and, when stderr is a terminal, to stderr. Callable from any thread.
///
/// Log what helps debug from the file alone: engine command lines, every engine stdout line,
/// the stderr tail on failure, state transitions.
enum Log {
    static func info(_ message: String) {
        writer.write(.info, message)
    }

    static func error(_ message: String) {
        writer.write(.error, message)
    }

    /// Blocks until everything logged so far is on disk. Call before `exit`.
    static func flush() {
        writer.flush()
    }

    static var fileURL: URL { writer.fileURL }

    /// `BOOTH_LOG_DIR` overrides the directory (sandboxes). Test runs, whose process isn't Booth,
    /// log to a temporary folder so they never fill the user's log.
    private static let writer = LogWriter(directory: directory(ProcessInfo.processInfo))

    private static func directory(_ process: ProcessInfo) -> URL {
        if let override = process.environment["BOOTH_LOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if process.processName != "Booth" {
            return FileManager.default.temporaryDirectory.appendingPathComponent("BoothTestLogs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Booth", isDirectory: true)
    }
}

private final class LogWriter: @unchecked Sendable {
    enum Level: String {
        case info = "INFO"
        case error = "ERROR"
    }

    let fileURL: URL
    private let rotatedURL: URL
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    // Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "studio.booth.log", qos: .utility)
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let timestamp: DateFormatter
    private let logger = Logger(subsystem: "studio.booth.Booth", category: "app")
    private let echoToStderr = isatty(STDERR_FILENO) == 1

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("booth.log")
        rotatedURL = directory.appendingPathComponent("booth.log.1")
        timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ level: Level, _ message: String) {
        let date = Date()
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        queue.async { [self] in
            let line = "\(timestamp.string(from: date)) [\(ProcessInfo.processInfo.processIdentifier)] \(level.rawValue) \(message)\n"
            let data = Data(line.utf8)
            if echoToStderr { FileHandle.standardError.write(data) }
            append(data)
        }
    }

    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func append(_ data: Data) {
        if handle == nil { open() }
        if size + UInt64(data.count) > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {
            self.handle = nil
        }
    }

    private func open() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: rotatedURL)
        try? manager.moveItem(at: fileURL, to: rotatedURL)
        open()
    }
}
