import Foundation
import XCTest
@testable import UsageCore

/// Fase 2 parity: cookies, fetch result handling, block logging, service status.
final class FetchParityTests: FixtureCase {
    func hex(_ s: String) -> Data {
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            data.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    func testDeriveCookieKey() {
        for c in list("derive_cookie_key") {
            XCTAssertEqual(deriveCookieKey(c["password"] as! String), hex(c["out"] as! String), "\(c)")
        }
    }

    func testDecryptCookieValue() {
        for c in list("decrypt_cookie_value") {
            let got = decryptCookieValue(hex(c["enc"] as! String), host: c["host"] as! String,
                                         key: hex(c["key"] as! String))
            XCTAssertEqual(got, c["out"] as? String, "\(c)")
        }
    }

    func testReadCookies() {
        let c = cases["read_cookies"] as! JSONObject
        let db = Self.testsDir.appendingPathComponent("Fixtures/Cookies")
        let got = readCookies(db: db, key: deriveCookieKey(c["password"] as! String))
        let want = (c["out"] as! [String: [String: String]]).mapValues {
            Cookie(value: $0["value"]!, domain: $0["domain"]!, path: $0["path"]!)
        }
        XCTAssertEqual(got, want)
        XCTAssertEqual(readCookies(db: db, key: deriveCookieKey("wrong")), [:])
    }

    func testPlanLabel() {
        for c in list("plan_label") {
            XCTAssertEqual(planLabel(c["in"]), c["out"] as! String, "\(c)")
        }
    }

    func testLimitsOutput() {
        for c in list("limits_output") {
            assertSame(limitsOutput(c["in"] as! JSONObject, now: formatter.now), c["out"], "\(c)")
        }
        let micro = parseDate("2026-10-01T11:01:13.494788+00:00")!
        XCTAssertEqual(pyIsoformatUTC(micro), "2026-10-01T11:01:13.494788+00:00")
    }

    func testNewBlockLogEntries() {
        for c in list("new_block_log_entries") {
            let (entries, seen) = newBlockLogEntries(limits: c["limits"] as! JSONObject,
                                                     bootstrapFields: c["bootstrap"],
                                                     account: c["account"] as! String,
                                                     seen: c["seen"] as! JSONObject)
            let out = c["out"] as! [Any]
            XCTAssertEqual(entries, out[0] as! [String], "\(c)")
            assertSame(seen, out[1], "\(c)")
        }
    }

    func testCedarEmber() {
        for c in list("cedar_ember") {
            let limits = c["limits"] as! JSONObject
            XCTAssertEqual(cedarEmberUnrecognised(limits), c["unrecognised"] as! Bool, "\(c)")
            assertSame(cedarEmberStable(limits), c["stable"], "\(c)")
        }
    }

    func testServiceStatus() {
        for c in list("service_status") {
            assertSame(serviceStatus(c["in"]), c["out"], "\(c)")
        }
    }

    func testFetchJSMatchesCore() {
        let js = try! String(contentsOf: Self.testsDir
            .appendingPathComponent("../../Resources/fetch.js").standardizedFileURL, encoding: .utf8)
        XCTAssertTrue(js.contains("const deliver = (s) => { DELIVER };"))
        XCTAssertTrue(buildFetchJS(template: js, deliver: "x(s);").contains("{ x(s); }"))
    }
}
