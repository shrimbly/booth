import Foundation

/// Locates files that `scripts/build-app.sh` copies into `Booth.app/Contents/Resources`.
/// When running unbundled in a debug build (`swift run`, tests) it falls back to `app/Resources`
/// in the source tree.
enum AppResources {
    #if DEBUG
    /// `app/Resources`, found relative to this source file.
    static let sourceTreeDirectory: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Model
        .deletingLastPathComponent() // Booth
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // app
        .appendingPathComponent("Resources", isDirectory: true)
    #else
    /// None in release builds: they would carry the build machine's path, and a shipped app must
    /// find everything in its own bundle.
    static let sourceTreeDirectory: URL? = nil
    #endif

    /// The URL of a resource such as `"Fonts/Newsreader-Italic.ttf"`, or nil when it is in
    /// neither the bundle nor the source tree.
    static func url(_ relativePath: String) -> URL? {
        let manager = FileManager.default
        for base in [Bundle.main.resourceURL, sourceTreeDirectory].compactMap({ $0 }) {
            let candidate = base.appendingPathComponent(relativePath)
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// True when running from an assembled `.app` rather than a bare build product.
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
