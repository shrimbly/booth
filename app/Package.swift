// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Booth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Booth", targets: ["Booth"]),
        .library(name: "BoothCore", targets: ["BoothCore"]),
    ],
    targets: [
        // Pure, Foundation-only logic shared by the app and its tests.
        .target(name: "BoothCore"),
        // The menu bar app (AppKit + SwiftUI). Resources are copied into Booth.app by
        // scripts/build-app.sh rather than declared here: Bundle.module does not survive
        // a hand-assembled bundle.
        .executableTarget(name: "Booth", dependencies: ["BoothCore"]),
        .testTarget(name: "BoothCoreTests", dependencies: ["BoothCore"]),
        // AppModel state machine tests, run against the executable target with fakes.
        .testTarget(name: "BoothTests", dependencies: ["Booth", "BoothCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
