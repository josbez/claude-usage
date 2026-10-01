import Foundation
import XCTest
@testable import UsageCore

/// Taak 48: the native fetch must deliver exactly what fetch.js delivers.
final class NativeFetchTests: XCTestCase {
    func org(_ id: String, raven: Any? = nil, name: String = "Example Org",
             caps: [String] = ["chat"], extra: JSONObject = [:]) -> JSONObject {
        var o: JSONObject = ["uuid": id, "name": name, "capabilities": caps,
                             "rate_limit_tier": "default_x", "plan_display_label": NSNull()]
        if let raven { o["raven_type"] = raven }
        for (k, v) in extra { o[k] = v }
        return ["organization": o]
    }

    func bootstrap(_ memberships: [JSONObject], account: JSONObject = [:], root: JSONObject = [:]) -> JSONObject {
        var acct: JSONObject = ["email_address": "user@example.com", "display_name": "Sam",
                                "memberships": memberships]
        for (k, v) in account { acct[k] = v }
        var d: JSONObject = ["account": acct]
        for (k, v) in root { d[k] = v }
        return d
    }

    func usage(_ util: Any?) -> JSONObject {
        ["five_hour": util.map { ["utilization": $0, "resets_at": "2026-10-01T12:00:00Z"] as JSONObject } ?? NSNull(),
         "seven_day": ["utilization": 10]]
    }

    func testPicksHighestFiveHourAndShapesResult() {
        let b = bootstrap([org("a"), org("b", raven: "team", caps: ["chat", "raven"])])
        let r = nativeFetchResult(bootstrap: b, orgs: fetchOrgs(bootstrap: b),
                                  usage: ["a": usage(12), "b": usage(40)])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["org_id"] as? String, "b")
        XCTAssertEqual(r["account_email"] as? String, "user@example.com")
        XCTAssertEqual(r["account_name"] as? String, "Sam")
        XCTAssertEqual(r["account_org"] as? String, "Example Org")
        let plan = r["account_plan"] as! JSONObject
        XCTAssertEqual(plan["raven"] as? String, "team")
        XCTAssertEqual(plan["label"] as? String, "")
        XCTAssertEqual(plan["capabilities"] as? [String], ["chat", "raven"])
        XCTAssertEqual(planLabel(plan), "Team")
        XCTAssertEqual(r["bootstrap_fields"] as? JSONObject as NSDictionary?, [:] as NSDictionary)
    }

    func testPersonalOrgNameNeverLeaves() {
        let b = bootstrap([org("a", name: "user@example.com's Organization", caps: ["claude_pro", "chat"])])
        let r = nativeFetchResult(bootstrap: b, orgs: fetchOrgs(bootstrap: b), usage: ["a": usage(5)])
        XCTAssertEqual(r["account_org"] as? String, "")
        XCTAssertEqual(planLabel(r["account_plan"]), "Pro")
    }

    func testTieKeepsFirstAndNullFiveHourCountsAsZero() {
        let b = bootstrap([org("a"), org("b")])
        let orgs = fetchOrgs(bootstrap: b)
        XCTAssertEqual(nativeFetchResult(bootstrap: b, orgs: orgs, usage: ["a": usage(7), "b": usage(7)])["org_id"] as? String, "a")
        // five_hour: null is still a usage response (fetch.js only skips undefined)
        XCTAssertEqual(nativeFetchResult(bootstrap: b, orgs: orgs, usage: ["b": usage(nil)])["org_id"] as? String, "b")
    }

    func testOrgsWithoutUsageAreSkipped() {
        let b = bootstrap([org("api", caps: ["api"]), org("b")])
        let r = nativeFetchResult(bootstrap: b, orgs: fetchOrgs(bootstrap: b),
                                  usage: ["api": ["error": "x"], "b": usage(3)])
        XCTAssertEqual(r["org_id"] as? String, "b")
        XCTAssertFalse(isUsageResponse(["error": "x"]))
    }

    func testNoUsableOrg() {
        let b = bootstrap([org("a")])
        XCTAssertEqual(nativeFetchResult(bootstrap: b, orgs: fetchOrgs(bootstrap: b), usage: [:]) as NSDictionary,
                       ["ok": false, "error": "no org with usage data"] as NSDictionary)
        XCTAssertEqual(nativeFetchResult(bootstrap: "html", orgs: fetchOrgs(bootstrap: "html"), usage: [:])["ok"] as? Bool, false)
        XCTAssertTrue(fetchOrgs(bootstrap: ["account": ["memberships": [["organization": ["name": "no uuid"]]]]]).isEmpty)
    }

    func testFallbacksForEmailAndName() {
        let b = bootstrap([org("a")], account: ["email_address": "", "email": "alt@example.com",
                                                 "display_name": NSNull(), "full_name": "Sam Full"])
        let r = nativeFetchResult(bootstrap: b, orgs: fetchOrgs(bootstrap: b), usage: ["a": usage(1)])
        XCTAssertEqual(r["account_email"] as? String, "alt@example.com")
        XCTAssertEqual(r["account_name"] as? String, "Sam Full")
    }

    func testBlockFieldsFromOrgOrRootUsingJSTruthiness() {
        let b = bootstrap([org("a", extra: ["access_block": ["reason": "x"], "billing_issue": NSNull(),
                                            "subscription_pause": [:] as JSONObject])],
                          root: ["api_disabled_until": "2026-11-01", "billing_issue": ""])
        let r = nativeFetchResult(bootstrap: b, orgs: fetchOrgs(bootstrap: b), usage: ["a": usage(1)])
        let fields = r["bootstrap_fields"] as! JSONObject
        XCTAssertEqual(Set(fields.keys), ["access_block", "subscription_pause", "api_disabled_until"])
    }

    func testResultFeedsLimitsOutput() {
        let b = bootstrap([org("a", raven: "team")])
        let r = nativeFetchResult(bootstrap: b, orgs: fetchOrgs(bootstrap: b), usage: ["a": usage(22)])
        let out = limitsOutput(r, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(out["account_plan"] as? String, "Team")
        XCTAssertEqual(out["account_org"] as? String, "Example Org")
        XCTAssertEqual(((out["five_hour"] as? JSONObject)?["utilization"] as? NSNumber)?.intValue, 22)
    }
}
