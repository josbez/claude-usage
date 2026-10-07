import Foundation
import XCTest
@testable import UsageCore

/// Taak 55b: one snapshot format for every source; Claude converts into it.
final class UsageSourcesTests: XCTestCase {
    let now = parseDate("2026-10-07T12:00:00Z")!

    /// Shaped like ~/.claude/usage-limits.json, with placeholder account data.
    func limits(_ extra: JSONObject = [:]) -> JSONObject {
        var l: JSONObject = [
            "fetched_at": "2026-10-07T11:59:30.123456+00:00",
            "account_email": "user@example.com", "account_name": "Test User",
            "account_org": "", "account_plan": "Pro",
            "five_hour": ["utilization": 42.0, "resets_at": "2026-10-07T15:00:00.123456+00:00",
                          "limit_dollars": NSNull(), "locked_reason": NSNull()],
            "seven_day": ["utilization": 17, "resets_at": "2026-10-12T09:00:00+00:00"],
            "seven_day_opus": NSNull(), "seven_day_sonnet": NSNull(),
            "seven_day_breakdown": ["rows": [["key": "chat", "percent": 100]]],
        ]
        l.merge(extra) { $1 }
        return l
    }

    func testClaudeWindows() {
        let s = claudeSnapshot(limits: limits(), now: now)
        XCTAssertEqual(s.windows, [
            UsageWindow(id: "five_hour", kind: .session, utilization: 42,
                        resetsAt: parseDate("2026-10-07T15:00:00.123456+00:00")),
            UsageWindow(id: "seven_day", kind: .weekly, utilization: 17,
                        resetsAt: parseDate("2026-10-12T09:00:00+00:00")),
        ])
        XCTAssertEqual(s.window(.session)?.utilization, 42)
        XCTAssertEqual(s.window(.weekly)?.utilization, 17)
        XCTAssertNil(s.window(.other))
        XCTAssertEqual(s.fetchedAt, parseDate("2026-10-07T11:59:30.123456+00:00"))
    }

    func testClaudeSourceHasNoPersonalDataInItsId() {
        let s = claudeSnapshot(limits: limits(), now: now)
        XCTAssertEqual(s.source, UsageSource(id: "claude-desktop", tool: "claude", accountLabel: "Test User"))
        XCTAssertEqual(s.plan, "Pro")
        XCTAssertFalse(s.source.id.contains("example"))
    }

    func testMissingWindowIsAbsentNotZero() {
        let s = claudeSnapshot(limits: limits(["five_hour": NSNull(), "seven_day": ["resets_at": "2026-10-12T09:00:00Z"]]),
                               now: now)
        XCTAssertEqual(s.windows, [])
        XCTAssertNil(s.window(.session))
        // A boolean is not a percentage.
        XCTAssertEqual(claudeSnapshot(limits: limits(["five_hour": ["utilization": true]]), now: now)
                        .window(.session), nil)
    }

    func testModelWindowsOnlyWhenReported() {
        let s = claudeSnapshot(limits: limits(["seven_day_opus": ["utilization": 5, "resets_at": NSNull()]]), now: now)
        XCTAssertEqual(s.windows.last, UsageWindow(id: "seven_day_opus", kind: .other, utilization: 5, resetsAt: nil))
        XCTAssertEqual(s.windows.count, 3)
    }

    func testResetCreditsFollowLimitResets() {
        XCTAssertNil(claudeSnapshot(limits: limits(), now: now).resetCredits)
        let ce: JSONObject = ["eligible": true, "grants": [
            ["resets_left": 1, "ends_at": "2026-10-20T00:00:00Z", "label": "Gift"],
            ["resets_left": 1, "ends_at": "2026-10-01T00:00:00Z"],   // expired
        ]]
        XCTAssertEqual(claudeSnapshot(limits: limits(["cedar_ember": ce]), now: now).resetCredits,
                       ResetCredits(available: 1, nextExpiry: parseDate("2026-10-20T00:00:00Z"), labels: ["Gift"]))
    }

    func testExtrasKeepTheRawClaudeData() {
        let s = claudeSnapshot(limits: limits(), now: now)
        XCTAssertNotNil(s.extras["seven_day_breakdown"] as? JSONObject)
        XCTAssertEqual(s.extras["account_plan"] as? String, "Pro")
    }

    func testEmptyLimitsFile() {
        let s = claudeSnapshot(limits: [:], now: now)
        XCTAssertEqual(s.windows, [])
        XCTAssertNil(s.fetchedAt)
        XCTAssertNil(s.plan)
        XCTAssertNil(s.resetCredits)
        XCTAssertEqual(s.source.id, "claude-desktop")
    }

    func testWindowKindFromMinutes() {
        XCTAssertEqual(windowKind(durationMinutes: 300), .session)
        XCTAssertEqual(windowKind(durationMinutes: 10080), .weekly)
        XCTAssertEqual(windowKind(durationMinutes: 60), .other)
        XCTAssertEqual(windowKind(durationMinutes: 0), .other)
    }
}
