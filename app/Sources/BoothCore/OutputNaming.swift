import Foundation

public enum MediaKind: String, Sendable {
    case audio, video
}

/// Which files Booth takes, and where their enhanced copies go (SPEC §1.6).
public enum OutputNaming {
    public static let suffix = "-enhanced"

    /// Audio containers ffmpeg reads that people actually have lying around. The second row was
    /// added after a real `enhance … --audio-only` run on each (Sun/NeXT au and snd, AC-3, E-AC-3,
    /// MPEG Layer II, iPhone ringtones, Sony Wave64).
    public static let audioExtensions: Set<String> = [
        "wav", "wave", "mp3", "m4a", "m4b", "aac", "flac", "aif", "aiff", "aifc", "caf",
        "ogg", "oga", "opus", "wma", "mka",
        "au", "snd", "ac3", "eac3", "mp2", "m4r", "w64",
    ]

    /// Video containers the engine can remux into. 3GPP2, F4V and QuickTime `.qt` were added
    /// after a real keep-video run on each (the engine names the mov muxer for `.qt`, which
    /// ffmpeg can't infer from the extension).
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mts", "m2ts", "ts", "mpg", "mpeg", "3gp", "wmv", "flv",
        "3g2", "f4v", "qt",
    ]

    /// Every extension Booth takes, lowercase and sorted: the file chooser's filter.
    public static let supportedExtensions: [String] = audioExtensions.union(videoExtensions).sorted()

    public static func mediaKind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Judged by extension only; whether the file really has sound is the engine's call
    /// (it answers `no_audio` / `decode_failed`).
    public static func isSupported(_ url: URL) -> Bool {
        url.isFileURL && !url.hasDirectoryPath && mediaKind(of: url) != nil
    }

    /// Splits dropped URLs into the ones Booth takes and the rest, keeping order.
    public static func partition(_ urls: [URL]) -> (supported: [URL], rejected: [URL]) {
        var supported: [URL] = []
        var rejected: [URL] = []
        for url in urls {
            if isSupported(url) { supported.append(url) } else { rejected.append(url) }
        }
        return (supported, rejected)
    }

    /// `<dir>/<stem>-enhanced.<ext>`, then `<stem>-enhanced 2.<ext>`, `3`, … until nothing is in
    /// the way. Video kept as video keeps its container extension; everything else becomes
    /// `.wav`. A video output also claims the `.wav` of the same name, because the engine
    /// writes that file next to it.
    public static func outputURL(for input: URL, keepVideo: Bool = true, isTaken: (URL) -> Bool = fileExists) -> URL {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let keepsContainer = keepVideo && mediaKind(of: input) == .video && !input.pathExtension.isEmpty
        let ext = keepsContainer ? input.pathExtension : "wav"

        var attempt = 1
        while true {
            let base = attempt == 1 ? stem + suffix : "\(stem)\(suffix) \(attempt)"
            let candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
            var claimed = [candidate]
            if keepsContainer { claimed.append(directory.appendingPathComponent(base).appendingPathExtension("wav")) }
            if !claimed.contains(where: isTaken) { return candidate }
            attempt += 1
        }
    }

    public static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
