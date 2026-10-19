import Foundation
import XCTest
@testable import UsageCore

/// Taak 43b: Claude Code as a source of its own, equal to the desktop app.
/// Placeholder ids and tokens only (public repo).
final class ClaudeCodeTests: XCTestCase {
    let now = parseDate("2026-10-07T12:00:00Z")!
    let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    var f: UsageFormatter { UsageFormatter(strings: FixtureCase.strings, now: now, timeZone: amsterdam) }
    let settings = normalizeSettings(["seasonal_faces": false])

    /// The usage body as the OAuth endpoint returns it (same shape as claude.ai's).
    func body(session: Double = 30, weekly: Double = 50) -> JSONObject {
        ["five_hour": ["utilization": session, "resets_at": "2026-10-07T14:40:00+00:00"],
         "seven_day": ["utilization": weekly, "resets_at": "2026-10-09T07:00:00+00:00"],
         "seven_day_opus": NSNull(), "extra_usage": ["is_enabled": false]]
    }

    func stored(session: Double = 30, weekly: Double = 50, plan: String? = "pro") -> JSONObject {
        let data = try! JSONSerialization.data(withJSONObject: body(session: session, weekly: weekly))
        guard case .limits(let obj) = claudeCodeOutcome(status: 200, body: data, plan: plan,
                                                        now: parseDate("2026-10-07T11:59:00Z")!) else {
            XCTFail("no limits"); return [:]
        }
        return obj
    }

    func desktop(session: Double = 42, org: String = "org-desktop") -> JSONObject {
        ["fetched_at": "2026-10-07T11:59:00+00:00", "org_id": org,
         "account_email": "user@example.com", "account_name": "Test User", "account_plan": "Team",
         "five_hour": ["utilization": session, "resets_at": "2026-10-07T14:40:00+00:00"],
         "seven_day": ["utilization": 61, "resets_at": "2026-10-09T07:00:00+00:00"]]
    }

    // MARK: - Account and token

    func testAccountFromClaudeJSON() {
        XCTAssertEqual(claudeCodeAccount(claudeJSON: ["oauthAccount": ["organizationUuid": "org-code"]]),
                       ClaudeCodeAccount(organizationId: "org-code"))
        XCTAssertNil(claudeCodeAccount(claudeJSON: [:]))
        XCTAssertNil(claudeCodeAccount(claudeJSON: ["oauthAccount": ["organizationUuid": ""]]))
    }

    func testOnlyAnotherAccountIsASource() {
        let code = ClaudeCodeAccount(organizationId: "org-code")
        XCTAssertTrue(claudeCodeIsSeparate(code, desktopLimits: desktop()))
        XCTAssertFalse(claudeCodeIsSeparate(ClaudeCodeAccount(organizationId: "org-desktop"), desktopLimits: desktop()))
        // Desktop app without an account: Claude Code counts
        XCTAssertTrue(claudeCodeIsSeparate(code, desktopLimits: [:]))
        XCTAssertFalse(claudeCodeIsSeparate(nil, desktopLimits: desktop()))
    }

    func testTokenFromKeychainValue() {
        let value = #"{"claudeAiOauth":{"accessToken":"tok-placeholder","refreshToken":"r","expiresAt":1791374400000,"subscriptionType":"pro"},"mcpOAuth":{}}"#
        let t = claudeCodeToken(keychainValue: value)!
        XCTAssertEqual(t.plan, "pro")
        XCTAssertNil(t.unknownPlan)
        XCTAssertEqual(t.expiresAt, Date(timeIntervalSince1970: 1791374400))
        XCTAssertFalse(t.description.contains("tok-placeholder"))
        XCTAssertFalse("\(t)".contains("tok-placeholder"))
        // Expired (or about to): not usable, no refresh attempt
        XCTAssertTrue(t.isUsable(now: Date(timeIntervalSince1970: 1791374400 - 3600)))
        XCTAssertFalse(t.isUsable(now: Date(timeIntervalSince1970: 1791374400 - 30)))

        let odd = claudeCodeToken(keychainValue: #"{"claudeAiOauth":{"accessToken":"x","subscriptionType":"galaxy"}}"#)!
        XCTAssertNil(odd.plan)
        XCTAssertEqual(odd.unknownPlan, "galaxy")
        XCTAssertTrue(odd.isUsable(now: now))
        XCTAssertNil(claudeCodeToken(keychainValue: "not json"))
        XCTAssertNil(claudeCodeToken(keychainValue: #"{"claudeAiOauth":{}}"#))
    }

    func testRequestHeaders() {
        let t = claudeCodeToken(keychainValue: #"{"claudeAiOauth":{"accessToken":"tok"}}"#)!
        let req = claudeCodeUsageRequest(token: t, appVersion: "3.3")
        XCTAssertEqual(req.url, claudeCodeUsageURL)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.httpMethod, "GET")
    }

    // MARK: - Response

    func testOutcomes() {
        XCTAssertEqual(claudeCodeOutcome(status: 401, body: nil, plan: nil, now: now), .unauthorized)
        XCTAssertEqual(claudeCodeOutcome(status: 403, body: nil, plan: nil, now: now), .unauthorized)
        XCTAssertEqual(claudeCodeOutcome(status: 429, body: nil, plan: nil, now: now), .rateLimited)
        XCTAssertEqual(claudeCodeOutcome(status: 500, body: nil, plan: nil, now: now), .failed("HTTP 500"))
        XCTAssertEqual(claudeCodeOutcome(status: 200, body: Data("x".utf8), plan: nil, now: now),
                       .failed("antwoord onleesbaar"))
        XCTAssertEqual(claudeCodeOutcome(status: 200, body: Data(#"{"limits":[]}"#.utf8), plan: nil, now: now),
                       .failed("geen limieten in het antwoord"))
        let s = stored()
        XCTAssertEqual(s["source"] as? String, claudeCodeSource)
        XCTAssertEqual(s["origin"] as? String, "oauth")
        XCTAssertEqual(s["plan"] as? String, "pro")
        XCTAssertNotNil(s["fetched_at"] as? String)
    }

    func testSnapshotIsClaudeShaped() {
        let snap = claudeCodeSnapshot(limits: stored(), now: now)!
        XCTAssertEqual(snap.source, UsageSource(id: claudeCodeSource, tool: "claude-code", accountLabel: ""))
        XCTAssertEqual(snap.window(.session)?.utilization, 30)
        XCTAssertEqual(snap.window(.weekly)?.utilization, 50)
        XCTAssertEqual(snap.plan, "pro")
        XCTAssertTrue(usesClaudeFormat(snap))
        // Another file (the desktop's) is not Claude Code's
        XCTAssertNil(claudeCodeSnapshot(limits: desktop(), now: now))
    }

    // MARK: - Equal to the other sources

    func testThreeEqualCards() {
        let code = claudeCodeSnapshot(limits: stored(session: 90), now: now)!
        let codex = SourceSnapshot(
            source: UsageSource(id: codexSource, tool: "codex", accountLabel: ""),
            windows: [UsageWindow(id: "primary", kind: .session, utilization: 18,
                                  resetsAt: parseDate("2026-10-07T18:16:00Z"))],
            fetchedAt: parseDate("2026-10-07T11:58:00Z"), plan: "plus", resetCredits: nil,
            extras: ["origin": "app-server"])
        let d = f.dashboardData(limits: desktop(), settings: settings, state: AppState(), lang: "en",
                                others: [code, codex])
        let cards = d["sources"] as! [JSONObject]
        XCTAssertEqual(cards.map { $0["id"] as? String }, [claudeDesktopSource, claudeCodeSource, codexSource])
        XCTAssertEqual(cards.map { $0["name"] as? String }, ["Claude", "Claude Code", "ChatGPT"])
        XCTAssertEqual(cards[1]["plan"] as? String, "Pro")
        // Claude Code gets the same week progress as the desktop card
        XCTAssertFalse(cards[1]["week_elapsed"] is NSNull)
        // The menu bar follows the tightest, without a name
        XCTAssertEqual((d["menubar_previews"] as? JSONObject)?["session"] as? String, "90%")
        let rows = d["source_rows"] as! [JSONObject]
        XCTAssertEqual(rows.map { $0["service"] as? Bool }, [true, true, false])
        XCTAssertEqual(rows.map { $0["live"] as? Bool }, [false, true, true])
        XCTAssertEqual(rows[1]["status"] as? String, "Connected through Claude Code · 1 min ago")
    }

    func testClaudeCodeAloneWithoutDesktop() {
        let code = claudeCodeSnapshot(limits: stored(), now: now)!
        let d = f.dashboardData(limits: [:], settings: settings, state: AppState(), lang: "nl", others: [code])
        XCTAssertEqual((d["sources"] as? [JSONObject])?.map { $0["id"] as? String }, [claudeCodeSource])
        XCTAssertEqual((d["menubar_previews"] as? JSONObject)?["session"] as? String, "30%")
    }

    // MARK: - Switched off: not fetched

    func testHiddenSourceStaysAvailableWhenOld() {
        // Hidden for weeks (not fetched): still listed, so it can be switched back on
        var old = stored()
        old["fetched_at"] = "2026-09-01T12:00:00+00:00"
        let code = claudeCodeSnapshot(limits: old, now: now)!
        XCTAssertEqual(availableSources(claude: nil, others: [code], now: now).count, 0)
        XCTAssertEqual(availableSources(claude: nil, others: [code], now: now, hidden: [claudeCodeSource]).count, 1)
        let d = f.dashboardData(limits: desktop(), settings: normalizeSettings(["seasonal_faces": false,
                                "hidden_sources": [claudeCodeSource]]), state: AppState(), lang: "en", others: [code])
        XCTAssertEqual((d["source_rows"] as? [JSONObject])?.map { $0["hidden"] as? Bool }, [false, true])
    }

    func testHiddenDesktopGivesNoStaleWarning() {
        var state = AppState()
        state.lastFetchError = "offline"
        let code = claudeCodeSnapshot(limits: stored(), now: now)!
        let s = normalizeSettings(["seasonal_faces": false, "hidden_sources": [claudeDesktopSource]])
        let d = f.dashboardData(limits: desktop(), settings: s, state: state, lang: "en", others: [code])
        XCTAssertEqual(d["status"] as? String, "ok")
        let shown = f.dashboardData(limits: desktop(), settings: settings, state: state, lang: "en", others: [code])
        XCTAssertEqual(shown["status"] as? String, "stale")
    }

    // MARK: - API key: a card without limits

    func testAPIKeyDetection() {
        XCTAssertTrue(claudeCodeUsesAPIKey(claudeJSON: [:], keychainItemExists: true))
        XCTAssertTrue(claudeCodeUsesAPIKey(claudeJSON: ["customApiKeyResponses": ["approved": ["abc"], "rejected": []]],
                                           keychainItemExists: false))
        XCTAssertFalse(claudeCodeUsesAPIKey(claudeJSON: ["customApiKeyResponses": ["approved": [], "rejected": []]],
                                            keychainItemExists: false))
        // A plan account wins: limits, not "API"
        XCTAssertFalse(claudeCodeUsesAPIKey(claudeJSON: ["oauthAccount": ["organizationUuid": "org-code"]],
                                            keychainItemExists: true))
    }

    func testAPICardSaysSoAndStaysOutOfTheMenuBar() {
        let api = claudeCodeAPISnapshot(now: now)
        let d = f.dashboardData(limits: desktop(session: 42), settings: settings, state: AppState(), lang: "en",
                                others: [api])
        let cards = d["sources"] as! [JSONObject]
        XCTAssertEqual(cards.map { $0["name"] as? String }, ["Claude", "Claude Code"])
        XCTAssertEqual(cards[1]["plan"] as? String, "API")
        XCTAssertEqual(cards[1]["note"] as? String, "Pay per use, no plan limits")
        XCTAssertTrue(cards[1]["session_pct"] is NSNull)
        XCTAssertTrue(cards[1]["updated"] is NSNull)
        XCTAssertEqual((d["source_rows"] as? [JSONObject])?[1]["status"] as? String, "Signed in with an API key")
        XCTAssertEqual((d["menubar_previews"] as? JSONObject)?["session"] as? String, "42%")

        // Only the API card: the menu bar has no numbers ("—"), never 0%
        let only = f.dashboardData(limits: [:], settings: settings, state: AppState(), lang: "en", others: [api])
        XCTAssertEqual((only["sources"] as? [JSONObject])?.map { $0["id"] as? String }, [claudeCodeSource])
        XCTAssertEqual((only["menubar_previews"] as? JSONObject)?["full"] as? String, "—")
        XCTAssertEqual(f.menubarTitle(limits: [:], others: [api], settings: settings, lang: "en").title, "—")
    }
}
