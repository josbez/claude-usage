import Foundation
import XCTest
@testable import UsageCore

final class SeasonalFacesTests: XCTestCase {
    let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!

    func date(_ iso: String) -> Date { parseDate(iso)! }

    func testHalloweenWindowInLocalTime() {
        // 20 Oct 00:00 through 31 Oct 23:59 Amsterdam (UTC+2 until 25 Oct 2026, then UTC+1)
        XCTAssertNil(activeFaceTheme(date("2026-10-19T21:59:00Z"), timeZone: amsterdam))
        XCTAssertEqual(activeFaceTheme(date("2026-10-19T22:00:00Z"), timeZone: amsterdam)?.id, "halloween")
        XCTAssertEqual(activeFaceTheme(date("2026-10-31T22:59:00Z"), timeZone: amsterdam)?.id, "halloween")
        XCTAssertNil(activeFaceTheme(date("2026-10-31T23:00:00Z"), timeZone: amsterdam))
        XCTAssertNil(activeFaceTheme(date("2026-06-15T12:00:00Z"), timeZone: amsterdam))
    }

    func testEveryThemeHasSevenFacesAndANameInBothLanguages() {
        let strings = try! Strings(contentsOf: FixtureCase.testsDir
            .appendingPathComponent("../../Resources/strings.json").standardizedFileURL)
        for theme in faceThemes {
            XCTAssertEqual(theme.faces.count, 7, theme.id)
            for lang in ["nl", "en"] {
                XCTAssertNotEqual(strings.t("theme_\(theme.id)", lang), "theme_\(theme.id)", "\(theme.id) \(lang)")
            }
        }
    }

    func testWindowsDontOverlap() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = amsterdam
        var day = cal.date(from: DateComponents(year: 2028, month: 1, day: 1))!   // leap year
        for _ in 0..<366 {
            let p = LocalParts(day, timeZone: amsterdam)
            let hits = faceThemes.filter { $0.contains(month: p.month, day: p.day) }.map(\.id)
            XCTAssertLessThanOrEqual(hits.count, 1, "\(p.day)-\(p.month): \(hits)")
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
    }

    func testWinterAndValentineWindows() {
        let want: [(String, String?)] = [
            ("2026-12-03T23:00:00Z", nil),           // 4 Dec 00:00 local
            ("2026-12-04T22:59:00Z", nil),
            ("2026-12-04T23:00:00Z", "christmas"),   // 5 Dec
            ("2026-12-25T22:59:00Z", "christmas"),
            ("2026-12-25T23:00:00Z", "newyear"),     // 26 Dec
            ("2026-12-31T23:30:00Z", "newyear"),     // 1 Jan, across the year
            ("2027-01-02T22:59:00Z", "newyear"),
            ("2027-01-02T23:00:00Z", nil),           // 3 Jan
            ("2027-02-11T22:59:00Z", nil),
            ("2027-02-11T23:00:00Z", "valentine"),   // 12 Feb
            ("2027-02-14T22:59:00Z", "valentine"),
            ("2027-02-14T23:00:00Z", nil),
        ]
        for (iso, id) in want {
            XCTAssertEqual(activeFaceTheme(date(iso), timeZone: amsterdam)?.id, id, iso)
        }
    }

    func testHalloweenFacesFollowTheThresholds() {
        let halloween = faceThemes.first { $0.id == "halloween" }
        let want = [0: "🎃", 19: "🎃", 20: "🕷️", 40: "🦇", 60: "👻", 75: "🧟", 89: "🧟",
                    90: "🪦", 99: "🪦", 100: "💀", 130: "💀"]
        for (pct, face) in want { XCTAssertEqual(faceIcon(pct, theme: halloween), face, "\(pct)") }
        XCTAssertEqual(faceIcon(45), "😅")   // no theme: the usual faces
    }

    func testStatusTitleUsesTheTheme() {
        let halloween = faceThemes.first { $0.id == "halloween" }
        XCTAssertEqual(statusTitle(session: 45, weekly: 82, compact: "2u10m", style: "session", theme: halloween),
                       "🦇 45%")
    }

    func testSettingSwitchesTheThemeOff() {
        let strings = try! Strings(contentsOf: FixtureCase.testsDir
            .appendingPathComponent("../../Resources/strings.json").standardizedFileURL)
        let f = UsageFormatter(strings: strings, now: date("2026-10-30T12:00:00Z"), timeZone: amsterdam)
        XCTAssertEqual(f.faceTheme(normalizeSettings(nil))?.id, "halloween")   // on by default
        XCTAssertNil(f.faceTheme(normalizeSettings(["seasonal_faces": false])))

        let data = f.dashboardData(limits: [:], settings: normalizeSettings(["seasonal_faces": false]),
                                   state: AppState(), lang: "nl")
        XCTAssertEqual((data["season_theme"] as? JSONObject)?["id"] as? String, "halloween")  // switch stays visible
        XCTAssertEqual(data["seasonal_faces"] as? Bool, false)
        XCTAssertEqual(data["session_face"] as? String, "🚀")

        let limits: JSONObject = ["five_hour": ["utilization": 92]]
        let on = f.dashboardData(limits: limits, settings: normalizeSettings(["menubar_icon": "emoji"]),
                                 state: AppState(), lang: "nl")
        XCTAssertEqual(on["session_face"] as? String, "🪦")   // the popover donut follows the theme
        XCTAssertEqual((on["menubar_previews"] as? JSONObject)?["emoji"] as? String, "🪦")
        XCTAssertEqual(strings.t("theme_halloween", "nl"), "Halloween, t/m 31 okt:")
    }

    func testInvalidSettingFallsBackToOn() {
        XCTAssertEqual(normalizeSettings(["seasonal_faces": 1])["seasonal_faces"] as? Bool, true)
        XCTAssertEqual(normalizeSettings(["seasonal_faces": "no"])["seasonal_faces"] as? Bool, true)
    }
}
