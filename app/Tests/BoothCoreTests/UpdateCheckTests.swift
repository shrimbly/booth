import BoothCore
import Foundation
import Testing

@Suite("Update check")
struct UpdateCheckTests {
    @Test func comparesVersionsNumberByNumber() {
        #expect(UpdateCheck.isNewer("v0.2.0", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.1"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        #expect(UpdateCheck.isNewer("0.1.1", than: "0.1"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("1.2", than: "1.2.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        // A build suffix doesn't make the same version newer.
        #expect(!UpdateCheck.isNewer("0.1.0+bbbbbbbbbbbb", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("latest", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("v", than: "0.1.0"))
    }

    @Test func readsGitHubsLatestRelease() throws {
        let json = """
            {"tag_name": "v0.2.0", "html_url": "https://github.com/shrimbly/booth/releases/tag/v0.2.0",
             "draft": false, "prerelease": false,
             "assets": [
               {"name": "Booth-0.2.0.dmg", "browser_download_url": "https://github.com/shrimbly/booth/releases/download/v0.2.0/Booth-0.2.0.dmg"},
               {"name": "Booth.dmg", "browser_download_url": "https://github.com/shrimbly/booth/releases/download/v0.2.0/Booth.dmg"},
               {"name": "SHA256SUMS", "browser_download_url": "https://github.com/shrimbly/booth/releases/download/v0.2.0/SHA256SUMS"}]}
            """
        let release = try #require(Release(gitHubJSON: Data(json.utf8)))
        #expect(release.version == "0.2.0")
        #expect(release.download.absoluteString == "https://github.com/shrimbly/booth/releases/download/v0.2.0/Booth.dmg")
    }

    @Test func withoutAnImageTheReleasePageIsTheDownload() throws {
        let json = #"{"tag_name": "v0.3.0", "html_url": "https://github.com/shrimbly/booth/releases/tag/v0.3.0", "assets": []}"#
        let release = try #require(Release(gitHubJSON: Data(json.utf8)))
        #expect(release.download.absoluteString == "https://github.com/shrimbly/booth/releases/tag/v0.3.0")
    }

    @Test func rejectsAnswersThatArentReleases() {
        #expect(Release(gitHubJSON: Data(#"{"message": "Not Found"}"#.utf8)) == nil)
        #expect(Release(gitHubJSON: Data(#"{"tag_name": "nightly", "html_url": "https://example.com"}"#.utf8)) == nil)
        #expect(Release(gitHubJSON: Data("<html>".utf8)) == nil)
    }
}
