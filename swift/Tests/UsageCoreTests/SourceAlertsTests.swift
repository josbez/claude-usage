import Foundation
import XCTest
@testable import UsageCore

/// Taak 55g (pure part): notifications and history per source.
final class SourceAlertsTests: FixtureCase {
    /// Claude through the per-source path gives the same state and ids as the
    /// existing Claude notifications, for every frozen case: switching later
    /// needs no migration and sends nothing twice.
    func testClaudeMatchesExistingNotifications() {
        var compared = 0
        for c in list("due_notifications") {
            var limits = c["limits"] as! JSONObject
            limits["fetched_at"] = isoString(formatter.now)
            let (notes, state) = formatter.dueNotifications(limits, state: c["state"] as! JSONObject,
                                                           lang: c["lang"] as! String)
            let (alerts, newState) = dueSourceAlerts(claudeSnapshot(limits: limits, now: formatter.now),
                                                     stateKey: string(limits, "account_email"),
                                                     state: c["state"] as! JSONObject, now: formatter.now)
            // The old path treats a missing utilization as 0%; the snapshot leaves the window out.
            let complete = ["five_hour", "seven_day"].allSatisfy {
                let b = limits[$0] as? JSONObject
                return b == nil || jsonNumber(b?["utilization"]) != nil
            }
            guard complete else { continue }
            compared += 1
            XCTAssertEqual(alerts.map(\.id), notes.map(\.id), "\(c)")
            XCTAssertEqual(alerts.map(\.threshold), notes.map(\.threshold), "\(c)")
            assertSame(newState, state, "\(c)")
        }
        XCTAssertGreaterThan(compared, 20)
    }

    let now = Date(timeIntervalSince1970: 1_791_386_000)

    func codex(session: Double, weekly: Double = 0, fetched: Date? = nil,
               sessionReset: Double = 1_791_396_969) -> SourceSnapshot {
        SourceSnapshot(source: UsageSource(id: "codex", tool: "codex", accountLabel: ""),
                       windows: [UsageWindow(id: "primary", kind: .session, utilization: session,
                                             resetsAt: Date(timeIntervalSince1970: sessionReset)),
                                 UsageWindow(id: "secondary", kind: .weekly, utilization: weekly,
                                             resetsAt: Date(timeIntervalSince1970: 1_791_983_769))],
                       fetchedAt: fetched ?? now, plan: "plus", resetCredits: nil, extras: [:])
    }

    func testThresholdsPerSource() {
        var (alerts, state) = dueSourceAlerts(codex(session: 50), stateKey: "codex", state: [:], now: now)
        XCTAssertEqual(alerts, [])
        (alerts, state) = dueSourceAlerts(codex(session: 81), stateKey: "codex", state: state, now: now)
        XCTAssertEqual(alerts.map(\.threshold), [80])
        XCTAssertEqual(alerts.first?.sourceId, "codex")
        XCTAssertEqual(alerts.first?.window, .session)
        XCTAssertTrue(alerts.first!.id.hasPrefix("codex|five_hour|"))
        // Same window, same level: nothing new.
        (alerts, state) = dueSourceAlerts(codex(session: 85), stateKey: "codex", state: state, now: now)
        XCTAssertEqual(alerts, [])
        // Jump past 95 and the weekly 90 at once: one per window, the highest.
        (alerts, state) = dueSourceAlerts(codex(session: 99, weekly: 91), stateKey: "codex", state: state, now: now)
        XCTAssertEqual(alerts.map(\.threshold), [95, 90])
        XCTAssertNotNil(state["codex|seven_day"])
    }

    func testSourcesDontShareState() {
        let (_, state) = dueSourceAlerts(codex(session: 81), stateKey: "codex", state: [:], now: now)
        let (alerts, _) = dueSourceAlerts(codex(session: 81), stateKey: "other-source", state: state, now: now)
        XCTAssertEqual(alerts.map(\.threshold), [80])
    }

    func testResetAfterWarning() {
        let (_, state) = dueSourceAlerts(codex(session: 81), stateKey: "codex", state: [:], now: now)
        // The next 5-hour window (later reset time), shortly after the old one ended.
        let later = Date(timeIntervalSince1970: 1_791_396_969 + 600)
        let (alerts, _) = dueSourceAlerts(codex(session: 2, fetched: later, sessionReset: 1_791_396_969 + 18_000),
                                          stateKey: "codex", state: state, now: later)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].isReset)
        XCTAssertEqual(alerts[0].pct, 2)
    }

    func testOldSnapshotGivesNoAlerts() {
        let old = now.addingTimeInterval(-(sourceAlertMaxAge + 1))
        let (alerts, state) = dueSourceAlerts(codex(session: 99, fetched: old), stateKey: "codex", state: ["x": 1], now: now)
        XCTAssertEqual(alerts, [])
        XCTAssertEqual(state.count, 1)   // untouched
    }

    func testWindowWithoutResetTimeIsSkipped() {
        let s = SourceSnapshot(source: UsageSource(id: "codex", tool: "codex", accountLabel: ""),
                               windows: [UsageWindow(id: "primary", kind: .session, utilization: 99, resetsAt: nil)],
                               fetchedAt: now, plan: nil, resetCredits: nil, extras: [:])
        XCTAssertEqual(dueSourceAlerts(s, stateKey: "codex", state: [:], now: now).0, [])
    }

    func testHistory() {
        let paths = Paths(isDev: false, home: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(historyDir(for: "claude-desktop", paths: paths).path, "/Users/someone/.claude/usage-history")
        XCTAssertEqual(historyDir(for: "codex", paths: paths).path, "/Users/someone/.claude/usage-history/codex")

        let rec = sourceHistoryRecord(codex(session: 12, weekly: 3))!
        XCTAssertEqual(rec["source"] as? String, "codex")
        XCTAssertEqual((rec["five_hour"] as? JSONObject)?["utilization"] as? Double, 12)
        XCTAssertEqual((rec["seven_day"] as? JSONObject)?["utilization"] as? Double, 3)
        XCTAssertEqual(rec["plan"] as? String, "plus")
        XCTAssertNil(rec["reset_credits"])
        let file = historyPath(rec["ts"] as! String, base: historyDir(for: "codex", paths: paths))
        XCTAssertEqual(file?.lastPathComponent, "2026-10.jsonl")

        let s = codex(session: 1)
        XCTAssertTrue(isNewHistoryRecord(s, lastRecorded: nil))
        XCTAssertFalse(isNewHistoryRecord(s, lastRecorded: now))
        XCTAssertTrue(isNewHistoryRecord(s, lastRecorded: now.addingTimeInterval(-60)))
    }
}
