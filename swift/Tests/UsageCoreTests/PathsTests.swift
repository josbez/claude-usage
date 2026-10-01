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

/// Taak 51: refresh interval setting (load_settings parity lives in the fixtures).
final class RefreshSettingTests: XCTestCase {
    func testRefreshMinutes() {
        XCTAssertEqual(refreshMinutes(normalizeSettings(nil)), 5)
        XCTAssertEqual(refreshMinutes(normalizeSettings(["refresh_minutes": 1])), 1)
        XCTAssertEqual(refreshMinutes(normalizeSettings(["refresh_minutes": 15])), 15)
        XCTAssertEqual(refreshMinutes(normalizeSettings(["refresh_minutes": 10])), 5)
        XCTAssertEqual(refreshMinutes(normalizeSettings(["refresh_minutes": true])), 5)
    }

    func testStaleThresholdGrowsWithInterval() {
        XCTAssertEqual(staleAfterMinutes(refresh: 1), 15)
        XCTAssertEqual(staleAfterMinutes(refresh: 5), 15)
        XCTAssertEqual(staleAfterMinutes(refresh: 15), 45)
    }
}

/// Taak 49: menu bar ring.
final class MenubarRingTests: XCTestCase {
    func testTemplateBelow75ColouredFrom75() {
        XCTAssertNil(menubarRing(sessionPct: 0).rgb)
        XCTAssertNil(menubarRing(sessionPct: 74).rgb)
        XCTAssertNotNil(menubarRing(sessionPct: 75).rgb)
        XCTAssertEqual(menubarRing(sessionPct: 100).rgb.map { [$0.0, $0.1, $0.2] }, [255, 59, 48])
        XCTAssertEqual(menubarRing(sessionPct: 42).fraction, 0.42)
        XCTAssertEqual(menubarRing(sessionPct: 140).fraction, 1)
        XCTAssertEqual(menubarRing(sessionPct: -3).fraction, 0)
    }

    func testTitleWithoutFace() {
        XCTAssertEqual(titleWithoutFace("😅 45% / 82% · 2u10m"), "45% / 82% · 2u10m")
        XCTAssertEqual(titleWithoutFace("😅 45%"), "45%")
        XCTAssertEqual(titleWithoutFace("😅"), "")
        XCTAssertEqual(titleWithoutFace("🚀 …"), "…")
    }

    func testIconSettingDefaultsToRing() {
        XCTAssertEqual(normalizeSettings(nil)["menubar_icon"] as? String, "ring")
        XCTAssertEqual(normalizeSettings(["menubar_icon": "emoji"])["menubar_icon"] as? String, "emoji")
        XCTAssertEqual(normalizeSettings(["menubar_icon": "x"])["menubar_icon"] as? String, "ring")
    }
}
