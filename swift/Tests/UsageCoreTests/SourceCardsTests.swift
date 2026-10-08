import Foundation
import XCTest
@testable import UsageCore

/// Taak 55f: cards per source, the tightest source in the menu bar, hiding sources.
final class SourceCardsTests: XCTestCase {
    let now = parseDate("2026-10-07T12:00:00Z")!
    let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    var f: UsageFormatter { UsageFormatter(strings: FixtureCase.strings, now: now, timeZone: amsterdam) }
    let settings = normalizeSettings(["seasonal_faces": false])

    /// Placeholder account data only (public repo).
    func claudeLimits(session: Double = 42, weekly: Double = 61) -> JSONObject {
        ["fetched_at": "2026-10-07T11:59:00+00:00",
         "account_email": "user@example.com", "account_name": "Test User", "account_plan": "Max",
         "five_hour": ["utilization": session, "resets_at": "2026-10-07T14:40:00+00:00"],
         "seven_day": ["utilization": weekly, "resets_at": "2026-10-09T07:00:00+00:00"]]
    }

    func codex(session: Double = 18, weekly: Double = 9, fetched: String = "2026-10-07T11:58:00Z",
               sessionReset: String = "2026-10-07T18:16:00Z", credits: ResetCredits? = nil,
               origin: String = "app-server") -> SourceSnapshot {
        SourceSnapshot(
            source: UsageSource(id: codexSource, tool: "codex", accountLabel: ""),
            windows: [UsageWindow(id: "primary", kind: .session, utilization: session, resetsAt: parseDate(sessionReset)),
                      UsageWindow(id: "secondary", kind: .weekly, utilization: weekly,
                                  resetsAt: parseDate("2026-10-13T12:00:00Z"))],
            fetchedAt: parseDate(fetched), plan: "plus", resetCredits: credits, extras: ["origin": origin])
    }

    var claude: SourceSnapshot { claudeSnapshot(limits: claudeLimits(), now: now) }

    // MARK: - Which sources

    func testAvailableSkipsEmptyAndOldSources() {
        let empty = claudeSnapshot(limits: [:], now: now)
        XCTAssertEqual(availableSources(claude: empty, others: [codex()], now: now).map(\.source.id), [codexSource])
        let old = codex(fetched: "2026-09-29T12:00:00Z")   // 8 days
        XCTAssertEqual(availableSources(claude: claude, others: [old], now: now).map(\.source.id), [claudeDesktopSource])
        XCTAssertEqual(availableSources(claude: claude, others: [codex()], now: now).map(\.source.id),
                       [claudeDesktopSource, codexSource])
    }

    func testHidingNeverLeavesNothing() {
        let both = [claude, codex()]
        XCTAssertEqual(visibleSources(both, hidden: [codexSource]).map(\.source.id), [claudeDesktopSource])
        XCTAssertEqual(visibleSources(both, hidden: [claudeDesktopSource, codexSource]).map(\.source.id),
                       [claudeDesktopSource])
        XCTAssertTrue(visibleSources([], hidden: []).isEmpty)
    }

    func testHiddenSourcesSettingIsCleaned() {
        XCTAssertEqual(normalizeSettings(nil)["hidden_sources"] as? [String], [])
        XCTAssertEqual(normalizeSettings(["hidden_sources": ["codex", "../x", 3, "codex"]])["hidden_sources"] as? [String],
                       ["codex", "codex"])
        XCTAssertEqual(hiddenSources(normalizeSettings(["hidden_sources": "codex"])), [])
    }

    // MARK: - Tightest source and menu bar

    func testTightestIsHighestOfSessionAndWeek() {
        XCTAssertEqual(tightestSource([claude, codex()], now: now)?.source.id, claudeDesktopSource)   // 61% week
        XCTAssertEqual(tightestSource([claude, codex(session: 81)], now: now)?.source.id, codexSource)
        // Tie: Claude (first) stays
        XCTAssertEqual(tightestSource([claude, codex(session: 61)], now: now)?.source.id, claudeDesktopSource)
        XCTAssertNil(tightestSource([], now: now))
    }

    func testAPassedResetCountsAsZero() {
        let reset = codex(session: 95, sessionReset: "2026-10-07T11:00:00Z")
        XCTAssertEqual(f.sourceSessionPct(reset), 0)
        XCTAssertEqual(pressure(reset, now: now), 9)
        XCTAssertEqual(tightestSource([claude, reset], now: now)?.source.id, claudeDesktopSource)
    }

    func testMenubarTitleNamesOtherSources() {
        XCTAssertEqual(f.sourceTitle(claude, style: "full", lang: "nl", theme: nil), "😅 42% / 61% · 2u40m")
        XCTAssertEqual(f.sourceTitle(codex(session: 81, weekly: 40), style: "full", lang: "nl", theme: nil),
                       "😰 ChatGPT 81% / 40% · 6u16m")
        XCTAssertEqual(f.sourceTitle(codex(), style: "session", lang: "en", theme: nil), "🚀 ChatGPT 18%")
        XCTAssertEqual(f.sourceTitle(codex(), style: "emoji", lang: "en", theme: nil), "🚀")
        // Ring mode drops the face; the name stays
        XCTAssertEqual(titleWithoutFace(f.sourceTitle(codex(), style: "session", lang: "nl", theme: nil)), "ChatGPT 18%")
    }

    func testClaudeTitleMatchesTheOldOne() {
        let limits = claudeLimits()
        for style in menubarStyles {
            XCTAssertEqual(f.sourceTitle(claudeSnapshot(limits: limits, now: now), style: style, lang: "nl", theme: nil),
                           f.titleFromLimits(limits, style: style, lang: "nl"))
        }
    }

    // MARK: - Cards

    func testClaudeCard() {
        let card = f.sourceCard(claude, settings: settings, lang: "nl", claudeLimits: claudeLimits())
        XCTAssertEqual(card["name"] as? String, "Claude")
        XCTAssertEqual(card["session_pct"] as? Int, 42)
        XCTAssertEqual(card["weekly_pct"] as? Int, 61)
        XCTAssertEqual(card["session_face"] as? String, "😅")
        XCTAssertEqual(card["session_reset"] as? String, "over 2u 40m")
        XCTAssertEqual(card["plan"] as? String, "Max")
        XCTAssertNotNil(jsonNumber(card["week_elapsed"]))
        XCTAssertTrue(card["resets"] is NSNull)
        XCTAssertTrue(card["updated"] is NSNull)
    }

    func testCodexCard() {
        let credits = ResetCredits(available: 2, nextExpiry: parseDate("2026-10-22T10:00:00Z"), labels: ["Full reset"])
        let card = f.sourceCard(codex(credits: credits), settings: settings, lang: "nl")
        XCTAssertEqual(card["name"] as? String, "ChatGPT")
        XCTAssertEqual(card["plan"] as? String, "Plus")
        XCTAssertEqual(card["session_pct"] as? Int, 18)
        // Week window: 7 days ending 13 okt 12:00 → 1 of 7 days in
        XCTAssertEqual(jsonNumber(card["week_elapsed"])!, 14.3, accuracy: 0.1)
        let resets = card["resets"] as! JSONObject
        XCTAssertEqual(resets["text"] as? String, "2 resets")
        XCTAssertEqual(resets["link"] as? Bool, false)
        XCTAssertEqual(resets["tip"] as? String, "2 resets beschikbaar · tot do 22 okt — Full reset")
    }

    func testMissingWindowStaysNullAndUnknownPlanIsHidden() {
        let s = SourceSnapshot(source: UsageSource(id: codexSource, tool: "codex", accountLabel: ""),
                               windows: [UsageWindow(id: "secondary", kind: .weekly, utilization: 9, resetsAt: nil)],
                               fetchedAt: now, plan: "team", resetCredits: nil, extras: [:])
        let card = f.sourceCard(s, settings: settings, lang: "en")
        XCTAssertTrue(card["session_pct"] is NSNull)
        XCTAssertTrue(card["session_reset"] is NSNull)
        XCTAssertTrue(card["plan"] is NSNull)
        XCTAssertTrue(card["week_elapsed"] is NSNull)
    }

    func testOldNumbersSaySo() {
        let card = f.sourceCard(codex(fetched: "2026-10-07T09:10:00Z", origin: "session-file"), settings: settings, lang: "nl")
        XCTAssertEqual(card["updated"] as? String, "bijgewerkt 11:10")
        XCTAssertEqual(f.sourceStatus(codex(fetched: "2026-10-05T09:10:00Z", origin: "session-file"), lang: "nl"),
                       "Uit de sessiebestanden van Codex · ma 5 okt")
        XCTAssertEqual(f.sourceStatus(codex(), lang: "en"), "Connected through Codex · 13:58")
    }

    // MARK: - Dashboard data

    func testOneSourceKeepsOldMenubarPreviewAndHasNoRows() {
        let d = f.dashboardData(limits: claudeLimits(), settings: settings, state: AppState(), lang: "nl")
        XCTAssertEqual((d["sources"] as? [JSONObject])?.count, 1)
        XCTAssertEqual((d["source_rows"] as? [Any])?.count, 0)
        XCTAssertEqual((d["menubar_previews"] as? JSONObject)?["full"] as? String, "42% / 61% · 2u40m")
    }

    func testTwoSourcesFollowTheTightest() {
        var s = settings
        let d = f.dashboardData(limits: claudeLimits(session: 10, weekly: 20), settings: s, state: AppState(),
                                lang: "nl", others: [codex(session: 81, weekly: 40)])
        XCTAssertEqual((d["sources"] as? [JSONObject])?.map { $0["id"] as? String }, ["claude-desktop", "codex"])
        XCTAssertEqual((d["menubar_previews"] as? JSONObject)?["full"] as? String, "ChatGPT 81% / 40% · 6u16m")
        XCTAssertEqual(jsonNumber((d["menubar_ring"] as? JSONObject)?["fraction"]), 0.81)
        let rows = d["source_rows"] as! [JSONObject]
        XCTAssertEqual(rows.map { $0["hidden"] as? Bool }, [false, false])

        s["hidden_sources"] = [codexSource]
        let hidden = f.dashboardData(limits: claudeLimits(session: 10, weekly: 20), settings: s, state: AppState(),
                                     lang: "nl", others: [codex(session: 81, weekly: 40)])
        XCTAssertEqual((hidden["sources"] as? [JSONObject])?.count, 1)
        XCTAssertEqual((hidden["source_rows"] as? [JSONObject])?.map { $0["hidden"] as? Bool }, [false, true])
        XCTAssertEqual((hidden["menubar_previews"] as? JSONObject)?["full"] as? String, "10% / 20% · 2u40m")
    }

    func testNothingFetchedStillShowsClaudesCard() {
        let d = f.dashboardData(limits: [:], settings: settings, state: AppState(), lang: "nl")
        let cards = d["sources"] as! [JSONObject]
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0]["session_pct"] is NSNull)
    }

    func testMenubarTitle() {
        let both = f.menubarTitle(limits: claudeLimits(session: 10, weekly: 20), others: [codex(session: 81, weekly: 40)],
                                  settings: settings, lang: "nl")
        XCTAssertEqual(both.title, "😰 ChatGPT 81% / 40% · 6u16m")
        XCTAssertEqual(both.sessionPct, 81)
        let alone = f.menubarTitle(limits: claudeLimits(), others: [], settings: settings, lang: "nl")
        XCTAssertEqual(alone.title, f.titleFromLimits(claudeLimits(), style: "full", lang: "nl"))
        let onlyCodex = f.menubarTitle(limits: [:], others: [codex()], settings: settings, lang: "nl")
        XCTAssertEqual(onlyCodex.title, "🚀 ChatGPT 18% / 9% · 6u16m")
    }
}
