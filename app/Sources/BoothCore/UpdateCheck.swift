import Foundation

/// A published release of Booth, as GitHub's latest-release answer describes it.
public struct Release: Equatable, Sendable {
    /// "0.2.0", from the tag "v0.2.0".
    public var version: String
    /// The release's disk image, else its page.
    public var download: URL

    public init(version: String, download: URL) {
        self.version = version
        self.download = download
    }

    /// GitHub's `releases/latest` JSON. nil when it has no version tag or nowhere to download
    /// from. Every release uploads its image as `Booth.dmg` as well as `Booth-<version>.dmg`.
    public init?(gitHubJSON data: Data) {
        struct Answer: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: URL
            }
            var tag_name: String
            var html_url: URL
            var assets: [Asset]?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              UpdateCheck.components(answer.tag_name) != nil else { return nil }
        let image = answer.assets?.first { $0.name == "Booth.dmg" }
            ?? answer.assets?.first { $0.name.hasPrefix("Booth") && $0.name.hasSuffix(".dmg") }
        version = answer.tag_name.hasPrefix("v") ? String(answer.tag_name.dropFirst()) : answer.tag_name
        download = image?.browser_download_url ?? answer.html_url
    }
}

/// Settings → Updates asks GitHub for the newest published release. Drafts and prereleases are
/// never the latest one.
public enum UpdateCheck {
    /// The repository whose releases hold Booth (`BOOTH_REPOSITORY` in packaging/release.env).
    public static let latestRelease = URL(string: "https://api.github.com/repos/shrimbly/booth/releases/latest")!

    /// Whether `candidate` is a later version than `current`. Numbers are compared part by part,
    /// so 0.10.0 is after 0.9.1 and 1.2 equals 1.2.0. A version that isn't one is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// "v1.2.3" or "1.2.3+abc" → [1, 2, 3]; nil without a number to start with.
    static func components(_ version: String) -> [Int]? {
        var text = Substring(version)
        if text.first == "v" { text = text.dropFirst() }
        let core = text.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }
}
