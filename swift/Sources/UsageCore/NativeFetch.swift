import Foundation

// Native fetch (taak 48): the same requests as Resources/fetch.js, made with
// URLSession instead of a hidden WKWebView on claude.ai. Measured 1-10-2026:
// claude.ai answers plain requests with the sessionKey cookie (no Cloudflare
// challenge), and it saves the ~70-400 MB WebContent process per fetch.
// The pure part lives here so it can mirror fetch.js exactly and be tested;
// the requests themselves are in the app (NativeFetching.swift).

/// JavaScript truthiness (fetch.js uses `||` and `if (v)`): unlike Python,
/// empty arrays and objects are truthy.
func jsTruthy(_ v: Any?) -> Bool {
    switch v {
    case nil, is NSNull: return false
    case let s as String: return !s.isEmpty
    case let n as NSNumber: return !(n.doubleValue == 0 || n.doubleValue.isNaN)
    default: return true
    }
}

/// `a || b` in JavaScript.
func jsOr(_ a: Any?, _ b: Any?) -> Any? { jsTruthy(a) ? a : b }

public struct FetchOrg {
    public let id: String
    let plan: JSONObject
    let orgName: String
    let organization: JSONObject
}

/// fetch.js, first half: the account's orgs, each with its raw plan data and
/// (only for shared orgs) its name. Order as in the bootstrap.
public func fetchOrgs(bootstrap: Any?) -> [FetchOrg] {
    let d = bootstrap as? JSONObject ?? [:]
    let acct = jsOr(d["account"], [:]) as? JSONObject ?? [:]
    let memberships = jsOr(acct["memberships"], []) as? [Any] ?? []
    return memberships.compactMap { m in
        let org = jsOr((m as? JSONObject)?["organization"], [:]) as? JSONObject ?? [:]
        guard jsTruthy(org["uuid"]), let id = org["uuid"] as? String else { return nil }
        let plan: JSONObject = [
            "label": jsOr(jsOr(org["plan_display_label"], org["plan_display_name"]), "") ?? "",
            "capabilities": jsOr(org["capabilities"], []) ?? [],
            "tier": jsOr(org["rate_limit_tier"], "") ?? "",
            "raven": jsOr(org["raven_type"], "") ?? "",
        ]
        // Org name only for shared (Team) orgs: personal orgs are named after the e-mail address
        let name = jsTruthy(org["raven_type"]) ? (jsOr(org["name"], "") as? String ?? "") : ""
        return FetchOrg(id: id, plan: plan, orgName: name, organization: org)
    }
}

/// Whether a usage response counts (fetch.js: `data.five_hour === undefined` skips).
public func isUsageResponse(_ data: Any?) -> Bool {
    (data as? JSONObject)?.keys.contains("five_hour") ?? false
}

/// fetch.js, second half: pick the org with the highest 5-hour utilization
/// (first one wins a tie) and shape the same result object fetch.js delivers.
/// `usage` holds the usable usage responses by org id.
public func nativeFetchResult(bootstrap: Any?, orgs: [FetchOrg], usage: [String: JSONObject]) -> JSONObject {
    let d = bootstrap as? JSONObject ?? [:]
    let acct = jsOr(d["account"], [:]) as? JSONObject ?? [:]
    let email = jsOr(jsOr(acct["email_address"], acct["email"]), "") ?? ""
    let name = jsOr(jsOr(acct["display_name"], acct["full_name"]), "") ?? ""

    var best: (util: Double, org: FetchOrg, data: JSONObject)? = nil
    for org in orgs {
        guard let data = usage[org.id], isUsageResponse(data) else { continue }
        let fiveHour = data["five_hour"] as? JSONObject
        let util = jsTruthy(fiveHour?["utilization"]) ? ((fiveHour?["utilization"] as? NSNumber)?.doubleValue ?? 0) : 0
        if best == nil || util > best!.util { best = (util, org, data) }
    }
    guard let best else { return ["ok": false, "error": "no org with usage data"] }

    // Block fields (taak 28): only when non-empty, on the chosen org or the root
    var bootstrapFields: JSONObject = [:]
    for f in ["access_block", "billing_issue", "subscription_pause", "api_disabled_reason", "api_disabled_until"] {
        let v = jsOr(best.org.organization[f], d[f])
        if jsTruthy(v) { bootstrapFields[f] = v }
    }
    return ["ok": true, "org_id": best.org.id, "account_email": email, "account_name": name,
            "account_plan": best.org.plan, "account_org": best.org.orgName,
            "bootstrap_fields": bootstrapFields, "data": best.data]
}
