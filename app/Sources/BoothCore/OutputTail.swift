import Foundation

/// The last lines of a process's stderr, kept so a crash can be explained to a person.
public struct OutputTail: Equatable, Sendable {
    public let maxLines: Int
    public let maxLineLength: Int
    public private(set) var lines: [String] = []

    public init(maxLines: Int = 40, maxLineLength: Int = 400) {
        self.maxLines = maxLines
        self.maxLineLength = maxLineLength
    }

    /// Adds one line as read from the pipe. Carriage-return redraws (tqdm, uv) keep only their
    /// final state, blank lines are dropped. Returns what was stored, or nil for nothing.
    @discardableResult
    public mutating func append(_ rawLine: String) -> String? {
        guard let line = Self.collapsingRedraws(rawLine) else { return nil }
        let clipped = line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…" : line
        lines.append(clipped)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return clipped
    }

    public var text: String { lines.joined(separator: "\n") }

    /// The line most likely to say what went wrong: the last one that is not a progress bar
    /// or a bare traceback frame.
    public var lastMeaningfulLine: String? {
        lines.last { !Self.isNoise($0) } ?? lines.last
    }

    /// The final state of a line that a progress bar redrew with `\r`.
    static func collapsingRedraws(_ line: String) -> String? {
        let segments = line.split(separator: "\r", omittingEmptySubsequences: true)
        guard let last = segments.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Progress bars ("45%|████"), traceback frames and separators say nothing on their own.
    static func isNoise(_ line: String) -> Bool {
        if line.hasPrefix("File \"") || line.hasPrefix("Traceback (most recent call last)") { return true }
        if line.contains("%|") { return true }
        return line.allSatisfy { "-=─━*~ ".contains($0) }
    }
}

/// Messages for engine runs that ended without saying why.
public enum EngineFailure {
    /// `"The engine stopped unexpectedly: <last stderr line>"`, followed by the rest of the tail
    /// on later lines. The Error screen shows only the first line (`Formatting.errorBody`).
    public static func message(exitStatus: Int32, signaled: Bool, tail: OutputTail) -> String {
        let headline: String
        if let reason = tail.lastMeaningfulLine {
            headline = "The engine stopped unexpectedly: \(reason)"
        } else if signaled {
            headline = "The engine stopped unexpectedly (signal \(exitStatus))."
        } else {
            headline = "The engine stopped unexpectedly (exit status \(exitStatus))."
        }
        let details = tail.text
        return details.isEmpty ? headline : headline + "\n\n" + details
    }

    /// The process exited cleanly but never sent `done` or `error`.
    public static let silentExit = "The engine stopped without reporting a result."
}
