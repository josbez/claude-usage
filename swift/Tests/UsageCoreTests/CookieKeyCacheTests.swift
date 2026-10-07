import Foundation
import XCTest
@testable import UsageCore

/// Taak 54: the Keychain is asked once per app start, not on every fetch.
final class CookieKeyCacheTests: FixtureCase {
    var password: String { (cases["read_cookies"] as! JSONObject)["password"] as! String }
    var rows: [CookieRow] { readCookieRows(db: Self.testsDir.appendingPathComponent("Fixtures/Cookies")) }
    var sessionValue: String {
        let out = (cases["read_cookies"] as! JSONObject)["out"] as! [String: [String: String]]
        return out["sessionKey"]!["value"]!
    }

    /// A cache whose Keychain answers come from `answers` (last one repeats).
    func makeCache(_ answers: [String], clock: @escaping () -> Date = Date.init)
        -> (CookieKeyCache, () -> [KeychainReadReason]) {
        var reads: [KeychainReadReason] = []
        var queue = answers
        let cache = CookieKeyCache(readPassword: {
            queue.count > 1 ? queue.removeFirst() : queue[0]
        }, now: clock, onRead: { reads.append($0) })
        return (cache, { reads })
    }

    func testRowsMatchReadCookies() {
        XCTAssertEqual(decryptCookies(rows, key: deriveCookieKey(password)),
                       readCookies(db: Self.testsDir.appendingPathComponent("Fixtures/Cookies"),
                                   key: deriveCookieKey(password)))
    }

    func testTenFetchesAskOnce() {
        let (cache, reads) = makeCache([password])
        for _ in 0..<10 { XCTAssertEqual(cache.sessionKey(rows: rows), .key(sessionValue)) }
        XCTAssertEqual(reads(), [.start])
    }

    func testLoggedOutNeverAsks() {
        let (cache, reads) = makeCache([password])
        let noSession = rows.filter { $0.name != "sessionKey" }
        for _ in 0..<5 { XCTAssertEqual(cache.sessionKey(rows: noSession), .loggedOut) }
        XCTAssertEqual(reads(), [])
        XCTAssertEqual(cache.sessionKey(rows: []), .loggedOut)
    }

    func testDenyWaitsAnHour() {
        var t = Date(timeIntervalSince1970: 1_000_000)
        let (cache, reads) = makeCache(["", password], clock: { t })
        XCTAssertEqual(cache.sessionKey(rows: rows), .noPassword)
        for _ in 0..<30 {
            t += 60
            XCTAssertEqual(cache.sessionKey(rows: rows), .waiting)
        }
        XCTAssertEqual(reads().count, 1)
        t += CookieKeyCache.retryInterval
        XCTAssertEqual(cache.sessionKey(rows: rows), .key(sessionValue))
        XCTAssertEqual(reads(), [.start, .retry])
    }

    func testRefreshButtonAllowsRetry() {
        var t = Date(timeIntervalSince1970: 1_000_000)
        let (cache, reads) = makeCache(["", password], clock: { t })
        XCTAssertEqual(cache.sessionKey(rows: rows), .noPassword)
        t += 60
        cache.allowRetry()
        XCTAssertEqual(cache.sessionKey(rows: rows), .key(sessionValue))
        XCTAssertEqual(reads(), [.start, .retry])
    }

    func testWrongPasswordIsNotRetriedEveryFetch() {
        var t = Date(timeIntervalSince1970: 1_000_000)
        let (cache, reads) = makeCache(["wrong"], clock: { t })
        XCTAssertEqual(cache.sessionKey(rows: rows), .noPassword)
        t += 60
        XCTAssertEqual(cache.sessionKey(rows: rows), .waiting)
        XCTAssertEqual(reads().count, 1)
    }

    func testKeyChangeAsksOnceMore() {
        // Rows encrypted with another password stand in for a rotated Safe Storage key.
        let (cache, reads) = makeCache([password, "other"])
        XCTAssertEqual(cache.sessionKey(rows: rows), .key(sessionValue))
        let session = rows.first { $0.name == "sessionKey" }!
        let garbled = CookieRow(name: "sessionKey", encrypted: Data("v10".utf8) + Data(repeating: 7, count: 32),
                                host: session.host, path: session.path)
        XCTAssertEqual(cache.sessionKey(rows: [garbled]), .noPassword)
        XCTAssertEqual(cache.sessionKey(rows: [garbled]), .waiting)
        XCTAssertEqual(reads(), [.start, .keyChanged])
    }

    func testNoDatabase() {
        let (cache, reads) = makeCache([password])
        XCTAssertEqual(cache.sessionKey(db: nil), .noDatabase)
        XCTAssertEqual(reads(), [])
    }
}
