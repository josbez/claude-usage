import Foundation
import XCTest
@testable import UsageCore

/// Taak 38: what "Uninstall…" may remove. Swift-only (no Python counterpart).
final class PathsTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")

    func names(_ urls: [URL]) -> [String] { urls.map { $0.path } }

    func testUninstallTargetsReleased() {
        let p = Paths(isDev: false, home: home)
        XCTAssertEqual(names(p.uninstallTargets(keepHistory: false)), [
            "/Users/someone/.claude/usage-limits.json",
            "/Users/someone/.claude/usage-tracker-blocks.json",
            "/Users/someone/.claude/usage-tracker-settings.json",
            "/Users/someone/.claude/usage-tracker-notified.json",
            "/Users/someone/.claude/usage-tracker-update.json",
            "/Users/someone/.claude/usage-history",
            "/Users/someone/Library/Logs/ClaudeUsage.log",
        ])
        XCTAssertEqual(p.launchAgent?.path,
                       "/Users/someone/Library/LaunchAgents/com.jos.claude-usage.plist")
    }

    func testKeepHistoryLeavesHistoryDir() {
        let p = Paths(isDev: false, home: home)
        let targets = names(p.uninstallTargets(keepHistory: true))
        XCTAssertFalse(targets.contains("/Users/someone/.claude/usage-history"))
        XCTAssertEqual(targets.count, 6)
    }

    func testDevBuildNeverTouchesReleasedFiles() {
        let dev = Paths(isDev: true, home: home)
        let released = Set(names(Paths(isDev: false, home: home).uninstallTargets(keepHistory: false)))
        let targets = names(dev.uninstallTargets(keepHistory: false))
        XCTAssertTrue(released.isDisjoint(with: targets), "\(targets)")
        XCTAssertTrue(targets.contains("/Users/someone/.claude/usage-history-dev"))
        XCTAssertNil(dev.launchAgent)
    }

    func testOnlyOwnFilesInClaudeDir() {
        for isDev in [false, true] {
            for url in Paths(isDev: isDev, home: home).uninstallTargets(keepHistory: false)
            where url.path.hasPrefix("/Users/someone/.claude/") {
                XCTAssertTrue(url.lastPathComponent.hasPrefix("usage-"), url.path)
            }
        }
    }
}
