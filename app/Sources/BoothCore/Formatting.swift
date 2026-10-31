import Foundation

/// Every user-visible string that is computed rather than fixed (SPEC §3.6). Copy is exact.
public enum Formatting {
    /// The first stage label, shown before the engine reports one.
    public static let firstStageLabel = "Reading audio"

    /// Whole percent, rounded half up like the prototype's `Math.round`.
    public static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded())
    }

    /// `"about 3 min left"` (≥ 90 s), `"about 1 min left"` (≥ 40 s), else `"under a minute left"`.
    public static func etaPhrase(seconds: Double) -> String {
        if seconds >= 90 { return "about \(Int((seconds / 60).rounded())) min left" }
        if seconds >= 40 { return "about 1 min left" }
        return "under a minute left"
    }

    /// Working screen: `"52% · Restoring the voice · about 1 min left"`. The ETA part is left out
    /// until the engine has given one.
    public static func statusLine(progress: Double, stageLabel: String, eta: Double?) -> String {
        let stage = stageLabel.isEmpty ? firstStageLabel : stageLabel
        var parts = ["\(percent(progress))%", stage]
        if let eta { parts.append(etaPhrase(seconds: eta)) }
        return parts.joined(separator: " · ")
    }

    /// `m:ss`, e.g. `"1:49"` or `"0:08"`.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let remainder = total % 60
        return "\(total / 60):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    /// `"Next: a.wav"` / `"Next: a.wav and 2 more"`; nil when nothing is queued.
    public static func queueLine(_ queuedNames: [String]) -> String? {
        guard let first = queuedNames.first else { return nil }
        let others = queuedNames.count - 1
        return others > 0 ? "Next: \(first) and \(others) more" : "Next: \(first)"
    }

    /// The Done screen's button for a job still running: `"In the booth: name · 34%"`.
    public static func backgroundJobLabel(name: String, progress: Double) -> String {
        "In the booth: \(name) · \(percent(progress))%"
    }

    /// Decimal sizes the way the setup screen shows them: `"412 MB"`, `"1.05 GB"`.
    public static func size(bytes: Int64) -> String {
        let megabytes = Int((Double(max(0, bytes)) / 1_000_000).rounded())
        if megabytes >= 1000 { return String(format: "%.2f GB", Double(megabytes) / 1000) }
        return "\(megabytes) MB"
    }

    /// First-run progress row, left side: `"412 MB of 1.13 GB"`.
    public static func setupBytes(done: Int64, total: Int64) -> String {
        "\(size(bytes: done)) of \(size(bytes: total))"
    }

    /// First-run progress row, right side: `"about 2 min left"` (never less than 1 min) or
    /// `"Done"`. Empty while the engine has not estimated a time yet.
    public static func setupTimeLeft(fraction: Double, eta: Double?) -> String {
        if fraction >= 1 { return "Done" }
        guard let eta else { return "" }
        return "about \(max(1, Int((eta / 60).rounded()))) min left"
    }

    /// `"3:12 · MP4 · 1080p"` for video, `"0:48 · M4A"` for audio or unknown height. The engine
    /// sends this in `start`; the app builds it only for the demo runner.
    public static func meta(duration: Double, fileExtension: String, height: Int? = nil) -> String {
        var parts = [clock(duration), fileExtension.uppercased()]
        if let height, height > 0 { parts.append("\(height)p") }
        return parts.joined(separator: " · ")
    }

    /// Error screen title. `fileCount` is how many files the error is about: more than one only
    /// when several unsupported files were rejected together.
    public static func errorTitle(for code: JobError.Code, fileCount: Int = 1) -> String {
        switch code {
        case .noAudio: "This file has no audio"
        case .decodeFailed: fileCount > 1 ? "Booth couldn't read these files" : "Booth couldn't read this file"
        default: "Something went wrong"
        }
    }

    /// Error screen body: the engine's sentence, cut to its first line for codes whose message
    /// may carry a traceback.
    public static func errorBody(for error: JobError) -> String {
        guard error.code != .noAudio && error.code != .decodeFailed else { return error.message }
        let firstLine = error.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    /// First-run failure title.
    public static let setupFailedTitle = "Setup didn't finish"

    /// First-run screen while the engine's `app-info` is slow to answer (often a macOS folder
    /// access prompt).
    public static let engineWaitingTitle = "Waiting for the engine"

    public static func engineWaitingBody(folder: String) -> String {
        "Booth's engine in \(folder) is taking a while to start. If macOS is asking whether Booth may access that folder, choose Allow."
    }

    /// First-run failure body when the engine never answered `app-info`.
    public static func engineUnresponsiveMessage(folder: String) -> String {
        "Booth's engine in \(folder) isn't answering. If macOS asked whether Booth may access that folder, choose Allow, then click Try again."
    }

    /// The folder to name for an engine executable: `~` for the home folder, and the project
    /// folder rather than its virtual environment (`~/proj/.venv/bin/booth` → `~/proj`).
    /// Without a `.venv`, the executable's own folder.
    public static func engineFolder(executablePath path: String, home: String) -> String {
        var folder = (path as NSString).deletingLastPathComponent
        if let venv = path.range(of: "/.venv/") { folder = String(path[..<venv.lowerBound]) }
        if folder.isEmpty { folder = "/" }
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard home.count > 1 else { return folder }
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    /// Error screen body when nothing dropped or chosen is a type Booth takes.
    /// `"notes.pdf isn't an audio or video file Booth can read. Nothing was changed."`, or with
    /// several, `"notes.pdf and 2 more aren't audio or video files Booth can read. …"`.
    public static func unsupportedFileBody(names: [String]) -> String {
        let first = names.first ?? "This file"
        let others = names.count - 1
        if others > 0 {
            return "\(first) and \(others) more aren't audio or video files Booth can read. Nothing was changed."
        }
        return "\(first) isn't an audio or video file Booth can read. Nothing was changed."
    }

    public static func unsupportedFileBody(name: String) -> String {
        unsupportedFileBody(names: [name])
    }

    /// Capsule HUD when ⌃⌥E finds only files Booth can't take selected in Finder.
    public static func unsupportedSelectionText(count: Int) -> String {
        count > 1 ? "Booth can't enhance the selected files" : "Booth can't enhance the selected file"
    }

    /// Error screen body when a background Save (remix) of a job that is no longer on screen fails.
    public static func remixFailedBody(name: String) -> String {
        "The new mix for \(name) wasn't saved. Its file still has the previous mix."
    }

    /// User notification body when a job finishes while the popover is closed.
    public static func notificationBody(name: String) -> String {
        "\(name) is out of the booth."
    }

    /// Capsule HUD after ⌃⌥E: `"In the booth: voice-memo.m4a"` / `"In the booth: 3 files"`.
    public static func capsuleText(enqueuedNames: [String]) -> String {
        switch enqueuedNames.count {
        case 0: nothingSelectedText
        case 1: "In the booth: \(enqueuedNames[0])"
        default: "In the booth: \(enqueuedNames.count) files"
        }
    }

    /// Capsule HUD when ⌃⌥E finds no supported file selected in Finder.
    public static let nothingSelectedText = "Select audio or video in Finder first"
}
