import Foundation
import XCTest
@testable import UsageCore

/// Fase 4 parity: version compare, release parsing, signature verification.
final class UpdateParityTests: FixtureCase {
    func testParseVersion() {
        for c in list("parse_version") {
            XCTAssertEqual(parseVersion(c["in"]), c["out"] as? [Int], "\(c)")
        }
    }

    func testIsNewer() {
        for c in list("is_newer") {
            XCTAssertEqual(isNewer(c["cand"] as! String, than: c["cur"] as! String), c["out"] as! Bool, "\(c)")
        }
    }

    func testParseRelease() {
        for c in list("parse_release") {
            assertSame(parseRelease(c["in"]), c["out"], "\(c)")
        }
    }

    func testUpdateCheckDue() {
        for c in list("update_check_due") {
            XCTAssertEqual(updateCheckDue(c["state"] as! JSONObject, now: formatter.now), c["out"] as! Bool, "\(c)")
        }
    }

    /// Taak 53: the refresh button checks after 5 min, not after a day.
    func testManualUpdateCheckBrake() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func state(minutesAgo: Double) -> JSONObject {
            ["last_check": pyIsoformatUTC(now.addingTimeInterval(-minutesAgo * 60))]
        }
        XCTAssertFalse(updateCheckDue(state(minutesAgo: 1), now: now, interval: manualUpdateCheckInterval))
        XCTAssertFalse(updateCheckDue(state(minutesAgo: 4.9), now: now, interval: manualUpdateCheckInterval))
        XCTAssertTrue(updateCheckDue(state(minutesAgo: 5), now: now, interval: manualUpdateCheckInterval))
        XCTAssertTrue(updateCheckDue([:], now: now, interval: manualUpdateCheckInterval))
        // The daily automatic check is unchanged.
        XCTAssertFalse(updateCheckDue(state(minutesAgo: 60), now: now))
    }

    func testVerifyReleaseSignature() {
        let v = cases["verify_release_signature"] as! JSONObject
        for c in v["cases"] as! [JSONObject] {
            XCTAssertEqual(verifyReleaseSignature(hexData(c["data"] as! String)!, c["sig"] as! String,
                                                  publicKeyHex: v["public_key"] as! String),
                           c["out"] as! Bool, "\(c)")
        }
        // Same release key as the former Python app: its signed releases verify here too.
        XCTAssertEqual(updatePublicKeyHex, v["release_public_key"] as! String)
    }

    func testUpdateErrorMessages() {
        let e = UpdateError("version_mismatch", ["got": "2.0", "expected": "2.1"], strings: Self.strings)
        XCTAssertEqual(e.message("en"), "version in DMG (2.0) doesn't match release (2.1)")
        XCTAssertEqual(e.description, "versie in DMG (2.0) klopt niet met release (2.1)")
    }
}
