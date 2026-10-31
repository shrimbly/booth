import Foundation
import Testing
@testable import Booth

/// Unbundled debug runs (`swift run`, these tests) find their resources and the engine source in
/// the source tree. Release builds don't compile that fallback in.
@Suite("App resources")
struct AppResourcesTests {
    @Test func debugBuildsFallBackToTheSourceTree() throws {
        let resources = try #require(AppResources.sourceTreeDirectory)
        #expect(resources.lastPathComponent == "Resources")
        #expect(AppResources.url("Booth.entitlements") == resources.appendingPathComponent("Booth.entitlements"))
        #expect(AppResources.url("no-such-resource") == nil)
    }

    @Test func unbundledEngineSourceIsTheRepository() throws {
        let resources = try #require(AppResources.sourceTreeDirectory)
        let repository = resources.deletingLastPathComponent().deletingLastPathComponent()
        let source = try #require(ManagedEngineInstaller.bundledSource())
        #expect(source.standardizedFileURL.path == repository.standardizedFileURL.path)
    }
}
