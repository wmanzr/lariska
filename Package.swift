// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Tests are optional: the target is declared only when its folder is present, so a checkout without
// Tests/ (they are not published) still builds.
let testsPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Tests/LariskaCoreTests").path
let hasTests = FileManager.default.fileExists(atPath: testsPath)

let package = Package(
    name: "lariska",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure DSP, music and game logic: no hardware, Swift 6 strict concurrency.
        .target(name: "LariskaCore"),
        // Hardware, terminal UI and modes. Talks to C callbacks and threads, so it stays in Swift 5 mode.
        .executableTarget(name: "lariska", dependencies: ["LariskaCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ] + (hasTests ? [.testTarget(name: "LariskaCoreTests", dependencies: ["LariskaCore"])] : [])
)
