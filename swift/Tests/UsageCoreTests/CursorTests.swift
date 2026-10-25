import Foundation
import SQLite3
import XCTest
@testable import UsageCore

/// Taak 41: Cursor as a source (monthly billing cycle).
final class CursorTests: XCTestCase {
    let now = parseDate("2026-10-25T12:00:00Z")!
    let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    var f: UsageFormatter { UsageFormatter(strings: FixtureCase.strings, now: now, timeZone: amsterdam) }
    let settings = normalizeSettings(["seasonal_faces": false])

    /// A made-up JWT (placeholder claims only, public repo).
    func jwt(exp: Double) -> String {
        let claims = try! JSONSerialization.data(withJSONObject: ["sub": "auth0|user_placeholder", "exp": exp])
        let b64 = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).signature"
    }

    /// The shape of a real response (25-10-2026), values replaced.
    func body(pct: Any? = 37, end: Any = "1794137534510") -> Data {
        var usage: JSONObject = ["remainingBonus": false, "autoPercentUsed": 20, "apiPercentUsed": 17]
        if let pct { usage["totalPercentUsed"] = pct }
        return try! JSONSerialization.data(withJSONObject: [
            "billingCycleStart": "1791459134510", "billingCycleEnd": end, "planUsage": usage,
            "spendLimitUsage": ["limitType": "user", "individualLimit": 0], "displayThreshold": 200])
    }

    func snapshot(pct: Double = 37) -> SourceSnapshot {
        guard case .snapshot(let s) = cursorOutcome(status: 200, body: body(pct: pct), plan: "free", now: now) else {
            fatalError("no snapshot")
        }
        return s
    }

    // MARK: - Login

    func testAuthFromValues() {
        let exp = now.timeIntervalSince1970 + 3600
        let a = cursorAuth(values: ["cursorAuth/accessToken": jwt(exp: exp), "cursorAuth/stripeMembershipType": "free"])!
        XCTAssertEqual(a.plan, "free")
        XCTAssertNil(a.unknownPlan)
        XCTAssertEqual(a.expiresAt, Date(timeIntervalSince1970: exp))
        XCTAssertTrue(a.isUsable(now: now))
        XCTAssertFalse(a.isUsable(now: now + 3570))
        XCTAssertFalse(String(describing: a).contains("eyJ"))
    }

    func testUnknownPlanIsNotShown() {
        let a = cursorAuth(values: ["cursorAuth/accessToken": jwt(exp: 0), "cursorAuth/stripeMembershipType": "pro_plus"])!
        XCTAssertNil(a.plan)
        XCTAssertEqual(a.unknownPlan, "pro_plus")
    }

    func testNotLoggedIn() {
        XCTAssertNil(cursorAuth(values: [:]))
        XCTAssertNil(cursorAuth(values: ["cursorAuth/accessToken": ""]))
    }

    func testTokenWithoutExpiryIsUsable() {
        let a = cursorAuth(values: ["cursorAuth/accessToken": "not-a-jwt"])!
        XCTAssertNil(a.expiresAt)
        XCTAssertTrue(a.isUsable(now: now))
    }

    func testReadsTheTwoValuesFromTheDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state.vscdb")
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &h), SQLITE_OK)
        sqlite3_exec(h, """
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'token-placeholder');
            INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', 'free');
            INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail', 'user@example.com');
            """, nil, nil, nil)
        sqlite3_close(h)
        let values = readCursorAuthValues(db: db)
        XCTAssertEqual(values, ["cursorAuth/accessToken": "token-placeholder", "cursorAuth/stripeMembershipType": "free"])
        XCTAssertEqual(readCursorAuthValues(db: dir.appendingPathComponent("missing.vscdb")), [:])
    }

    // MARK: - Response

    func testMonthlyWindowFromResponse() {
        let s = snapshot()
        XCTAssertEqual(s.source.id, cursorSource)
        XCTAssertEqual(s.windows, [UsageWindow(id: "billing_cycle", kind: .monthly, utilization: 37,
                                               resetsAt: Date(timeIntervalSince1970: 1794137534.510))])
        XCTAssertEqual(s.plan, "free")
        XCTAssertEqual(s.fetchedAt, now)
        XCTAssertTrue(hasLimits(s))
    }

    func testCycleEndAsNumber() {
        guard case .snapshot(let s) = cursorOutcome(status: 200, body: body(end: 1794137534510), plan: nil, now: now) else {
            return XCTFail("no snapshot")
        }
        XCTAssertEqual(s.windows.first?.resetsAt, Date(timeIntervalSince1970: 1794137534.510))
    }

    func testNoPercentageIsAFailureNotZero() {
        XCTAssertEqual(cursorOutcome(status: 200, body: body(pct: nil), plan: nil, now: now),
                       .failed("no plan usage in the response"))
        XCTAssertEqual(cursorOutcome(status: 200, body: Data("x".utf8), plan: nil, now: now), .failed("response unreadable"))
    }

    func testHTTPErrors() {
        XCTAssertEqual(cursorOutcome(status: 401, body: nil, plan: nil, now: now), .unauthorized)
        XCTAssertEqual(cursorOutcome(status: 403, body: nil, plan: nil, now: now), .unauthorized)
        XCTAssertEqual(cursorOutcome(status: 429, body: nil, plan: nil, now: now), .rateLimited)
        XCTAssertEqual(cursorOutcome(status: 500, body: nil, plan: nil, now: now), .failed("HTTP 500"))
    }

    func testRequestIsReadOnlyUsage() {
        let a = cursorAuth(values: ["cursorAuth/accessToken": "token-placeholder"])!
        let r = cursorUsageRequest(auth: a, appVersion: "3.4")
        XCTAssertEqual(r.url, cursorUsageURL)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer token-placeholder")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(r.httpBody, Data("{}".utf8))
    }

    func testSnapshotFileRoundTrip() {
        let s = snapshot()
        let back = UsageCore.snapshot(fromJSON: snapshotJSON(s, origin: "api"), sourceId: cursorSource)!
        XCTAssertEqual(back.windows, s.windows)
        XCTAssertEqual(back.source.tool, "cursor")
    }

    // MARK: - Card and menu bar

    func testCardShowsTheMonthInTheRing() {
        let card = f.sourceCard(snapshot(), settings: settings, lang: "en")
        XCTAssertEqual(card["name"] as? String, "Cursor")
        XCTAssertEqual(card["session_pct"] as? Int, 37)
        XCTAssertEqual(card["main_kind"] as? String, "month")
        XCTAssertEqual(card["session_reset"] as? String, f.shortDate(isoString(Date(timeIntervalSince1970: 1794137534.510)), "en"))
        XCTAssertTrue(card["weekly_pct"] is NSNull)
        XCTAssertEqual(card["plan"] as? String, "Free")
    }

    func testOtherCardsKeepTheSession() {
        let codex = SourceSnapshot(source: UsageSource(id: codexSource, tool: "codex", accountLabel: ""),
                                   windows: [UsageWindow(id: "primary", kind: .session, utilization: 18, resetsAt: nil)],
                                   fetchedAt: now, plan: nil, resetCredits: nil, extras: [:])
        XCTAssertEqual(f.sourceCard(codex, settings: settings, lang: "en")["main_kind"] as? String, "session")
    }

    func testMenuBarUsesTheMonthWithoutAResetTime() {
        let s = snapshot(pct: 37)
        XCTAssertEqual(f.sourceSessionPct(s), 37)
        XCTAssertEqual(pressure(s, now: now), 37)
        XCTAssertFalse(f.sourceTitle(s, style: "full", lang: "en", theme: nil).contains("h"))
    }

    func testNoNotificationsOrHistoryForAMonth() {
        let (alerts, _) = dueSourceAlerts(snapshot(pct: 99), stateKey: cursorSource, state: [:], now: now)
        XCTAssertEqual(alerts, [])
        XCTAssertEqual(sourceHistoryRecord(snapshot())?.keys.sorted(), ["plan", "source", "ts"])
    }
}
