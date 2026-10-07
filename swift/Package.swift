// swift-tools-version:5.9
// ClaudeUsage. UsageCore = pure logic (Foundation only, XCTest; ported from the
// former Python app, tested against its frozen fixtures); ClaudeUsage = AppKit glue.
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
