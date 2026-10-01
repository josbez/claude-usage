import Foundation

// What happens with a fetch result (core.py: limits_output, plan_label, block
// logging, cedar_ember logging). The fetch itself runs as JS inside claude.ai
// (Resources/fetch.js = core._FETCH_JS_TEMPLATE).

/// core.build_fetch_js(): deliver is a JS statement that consumes the result string `s`.
public func buildFetchJS(template: String, deliver: String) -> String {
    template.replacingOccurrences(of: "DELIVER", with: deliver)
}

/// Capability -> label, only for values actually observed (core.OBSERVED_PLAN_CAPABILITIES).
let observedPlanCapabilities = ["claude_pro": "Pro"]
/// raven_type -> label, observed for a Team org 1-10-2026 (core.OBSERVED_PLAN_RAVEN_TYPES).
let observedPlanRavenTypes = ["team": "Team"]

/// core.plan_label(): the API's label, else an observed capability, else "".
public func planLabel(_ plan: Any?) -> String {
    if let s = plan as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let p = plan as? JSONObject else { return "" }
    let label = (p["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !label.isEmpty { return label }
    for cap in p["capabilities"] as? [Any] ?? [] {
        if let c = cap as? String, let l = observedPlanCapabilities[c] { return l }
    }
    return observedPlanRavenTypes[p["raven"] as? String ?? ""] ?? ""
}

/// Python's datetime.isoformat() for a UTC time: microseconds only when non-zero.
public func pyIsoformatUTC(_ date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    let micro = Int((Double(c.nanosecond!) / 1000).rounded(.down))
    if micro > 0 { s += String(format: ".%06d", micro) }
    return s + "+00:00"
}

/// core.limits_output(): a successful fetch result as written to the limits file.
/// Keys from the API data win over ours, like Python's {**...}.
public func limitsOutput(_ parsed: JSONObject, now: Date) -> JSONObject {
    var out: JSONObject = [
        "fetched_at": pyIsoformatUTC(now),
        "org_id": parsed["org_id"] ?? NSNull(),
        "account_email": parsed["account_email"] ?? "",
        "account_name": parsed["account_name"] ?? "",
        "account_plan": planLabel(parsed["account_plan"]),
        "account_org": (parsed["account_org"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
    ]
    for (k, v) in parsed["data"] as? JSONObject ?? [:] { out[k] = v }
    return out
}

/// Python's str() of a JSON value, for log lines that must match core.py.
/// Dict key order follows Swift's (sorted), not the API's — only multi-key
/// dicts can differ, which at worst logs a block reason once more.
public func pyStr(_ v: Any?) -> String {
    func repr(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return "None"
        case let s as String:
            if s.contains("'") && !s.contains("\"") { return "\"\(s)\"" }
            return "'" + s.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'") + "'"
        default: return pyStr(v)
        }
    }
    switch v {
    case nil, is NSNull: return "None"
    case let s as String: return s
    case let n as NSNumber:
        if isJSONBool(n) { return n.boolValue ? "True" : "False" }
        if let i = jsonInt(n) { return String(i) }
        let d = n.doubleValue
        return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
    case let a as [Any]: return "[" + a.map { repr($0) }.joined(separator: ", ") + "]"
    case let d as JSONObject:
        return "{" + d.keys.sorted().map { "\(repr($0)): \(repr(d[$0]))" }.joined(separator: ", ") + "}"
    default: return "\(v!)"
    }
}

let blockFields = ["access_block", "billing_issue", "subscription_pause",
                   "api_disabled_reason", "api_disabled_until"]

/// core.new_block_log_entries(): new block reasons to log, once per
/// (account, field, value). Returns (log lines, updated seen).
public func newBlockLogEntries(limits: JSONObject, bootstrapFields: Any?, account: String,
                               seen: JSONObject) -> ([String], JSONObject) {
    var newSeen = seen
    var entries: [String] = []
    var fields: [(String, Any)] = []
    for key in ["five_hour", "seven_day"] {
        if let b = limits[key] as? JSONObject, truthy(b["locked_reason"]) {
            fields.append(("\(key)__locked_reason", b["locked_reason"]!))
        }
    }
    if let bs = bootstrapFields as? JSONObject {
        for f in blockFields where truthy(bs[f]) { fields.append((f, bs[f]!)) }
    }
    for (field, value) in fields {
        let valueStr = pyStr(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if valueStr.isEmpty { continue }
        let key = "\(account)|\(field)|\(valueStr)"
        if newSeen[key] == nil {
            entries.append("blokkering: \(field)=\(valueStr)")
            newSeen[key] = true
        }
    }
    return (entries, newSeen)
}

/// core.cedar_ember_unrecognised(): present, but not in the shape we have seen.
public func cedarEmberUnrecognised(_ limits: JSONObject) -> Bool {
    if limits["cedar_ember"] == nil || limits["cedar_ember"] is NSNull { return false }
    return grants(limits) == nil
}

/// core.cedar_ember_stable(): compact, stable subset for the log and history.
public func cedarEmberStable(_ limits: JSONObject) -> JSONObject? {
    guard let list = grants(limits), let ce = limits["cedar_ember"] as? JSONObject else { return nil }
    let keys = ["id", "resets_left", "resets_total", "starts_at", "ends_at", "paused", "usable_now"]
    return ["eligible": ce["eligible"] ?? NSNull(), "at_limit": ce["at_limit"] ?? NSNull(),
            "grants": list.map { (pick($0, keys) as Any?) ?? NSNull() }]
}

/// core._pick(): copy the given keys, skipping missing/None; nil when empty.
func pick(_ obj: Any?, _ keys: [String]) -> JSONObject? {
    guard let d = obj as? JSONObject else { return nil }
    var out: JSONObject = [:]
    for k in keys { if let v = d[k], !(v is NSNull) { out[k] = v } }
    return out.isEmpty ? nil : out
}
