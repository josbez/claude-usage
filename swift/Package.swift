// swift-tools-version:5.9
// ClaudeUsage, native (taak 35). UsageCore = pure logic (port of core.py, Foundation
// only, tested against fixtures from core.py); ClaudeUsage = AppKit glue (app.py).
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "ClaudeUsage", dependencies: ["UsageCore"]),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
