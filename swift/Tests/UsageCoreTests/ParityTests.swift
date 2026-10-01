import Foundation
import XCTest
@testable import UsageCore

/// Parity with core.py: every case in Fixtures/core.json was produced by the
/// Python function (scripts/swift-fixtures.py); the Swift port must give the
/// exact same output at the same "now" and time zone.
final class ParityTests: XCTestCase {
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixtures: JSONObject = {
        let url = testsDir.appendingPathComponent("Fixtures/core.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! JSONObject
    }()
    static let strings = try! Strings(contentsOf: testsDir
        .appendingPathComponent("../../Resources/strings.json").standardizedFileURL)

    var cases: JSONObject { Self.fixtures["cases"] as! JSONObject }
    var formatter: UsageFormatter {
        UsageFormatter(strings: Self.strings,
                  now: parseDate(Self.fixtures["now"] as! String)!,
                  timeZone: TimeZone(identifier: Self.fixtures["tz"] as! String)!)
    }

    func list(_ name: String) -> [JSONObject] { cases[name] as! [JSONObject] }

    /// Compare JSON-ish values the way Python's == does (1 == 1.0, None == NSNull).
    func assertSame(_ got: Any?, _ want: Any?, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        func norm(_ v: Any?) -> Any {
            switch v {
            case nil, is NSNull: return NSNull()
            case let d as [String: Any]: return d.mapValues { norm($0) } as NSDictionary
            case let a as [Any]: return a.map { norm($0) } as NSArray
            case let i as Int: return NSNumber(value: Double(i))
            case let d as Double: return NSNumber(value: d)
            case let n as NSNumber where !isJSONBool(n): return NSNumber(value: n.doubleValue)
            default: return v!
            }
        }
        XCTAssertEqual(norm(got) as? NSObject, norm(want) as? NSObject, msg, file: file, line: line)
    }

    func testFormatResetTime() {
        for c in list("format_reset_time") {
            XCTAssertEqual(formatter.resetTime(c["in"] as! String, c["lang"] as! String),
                           c["out"] as! String, "\(c)")
        }
    }

    func testFormatResetCompact() {
        for c in list("format_reset_compact") {
            XCTAssertEqual(formatter.resetCompact(c["in"] as! String, c["lang"] as! String),
                           c["out"] as! String, "\(c)")
        }
    }

    func testFormatShortDate() {
        for c in list("format_short_date") {
            XCTAssertEqual(formatter.shortDate(c["in"] as! String, c["lang"] as! String),
                           c["out"] as! String, "\(c)")
        }
    }

    func testFaceIcon() {
        for c in list("face_icon") {
            XCTAssertEqual(faceIcon(c["in"] as! Int), c["out"] as! String, "\(c)")
        }
    }

    func testStatusTitle() {
        for c in list("status_title") {
            XCTAssertEqual(statusTitle(session: c["session"] as! Int, weekly: c["weekly"] as! Int,
                                       compact: c["compact"] as! String, style: c["style"] as! String),
                           c["out"] as! String, "\(c)")
        }
    }

    func testTitleFromLimits() {
        for c in list("title_from_limits") {
            XCTAssertEqual(formatter.titleFromLimits(c["limits"] as! JSONObject, style: c["style"] as! String,
                                                     lang: c["lang"] as! String),
                           c["out"] as! String, "\(c)")
        }
    }

    func testAccountLabel() {
        for c in list("account_label") {
            assertSame(accountLabel(c["limits"] as! JSONObject), c["out"], "\(c)")
        }
    }

    func testWeekProgress() {
        for c in list("week_progress") {
            assertSame(weekProgress(c["limits"] as! JSONObject, now: formatter.now), c["out"], "\(c)")
        }
    }

    func testLimitsAreFresh() {
        for c in list("limits_are_fresh") {
            XCTAssertEqual(limitsAreFresh(c["limits"] as! JSONObject, now: formatter.now),
                           c["out"] as! Bool, "\(c)")
        }
    }

    func testLimitResetsView() {
        for c in list("limit_resets_view") {
            assertSame(formatter.limitResetsView(c["limits"] as! JSONObject, c["lang"] as! String),
                       c["out"], "\(c)")
        }
    }

    func testLoadSettings() {
        for c in list("load_settings") {
            assertSame(normalizeSettings(c["stored"]), c["out"], "\(c)")
        }
    }

    func testStatusBadgeClass() {
        for c in list("status_badge_class") {
            XCTAssertEqual(statusBadgeClass(c["in"] as? JSONObject), c["out"] as! String, "\(c)")
        }
    }

    func testT() {
        for c in list("t") {
            XCTAssertEqual(Self.strings.t(c["key"] as! String, c["lang"] as! String, c["kw"] as! JSONObject),
                           c["out"] as! String, "\(c)")
        }
    }

    func testLanguageFrom() {
        XCTAssertEqual(languageFrom(["nl-NL", "en-US"]), "nl")
        XCTAssertEqual(languageFrom(["nl_BE"]), "nl")
        XCTAssertEqual(languageFrom(["en-GB", "nl-NL"]), "en")
        XCTAssertEqual(languageFrom([]), "en")
    }

    func testParseDate() {
        XCTAssertNotNil(parseDate("2026-10-01T12:30:00Z"))
        XCTAssertNotNil(parseDate("2026-10-01T14:59:59.871234+00:00"))
        XCTAssertNil(parseDate("2026-02-30T10:00:00Z"))
        XCTAssertNil(parseDate("garbage"))
        XCTAssertEqual(parseDate("2026-10-01T12:00:00+02:00"), parseDate("2026-10-01T10:00:00Z"))
    }
}
