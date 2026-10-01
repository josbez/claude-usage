import Foundation

/// core.account_label(): name, shared org and plan for the footer; falls back to the e-mail.
public func accountLabel(_ limits: JSONObject) -> [String: String] {
    let email = string(limits, "account_email")
    let name = string(limits, "account_name").trimmingCharacters(in: .whitespacesAndNewlines)
    let org = string(limits, "account_org").trimmingCharacters(in: .whitespacesAndNewlines)
    let plan = string(limits, "account_plan").trimmingCharacters(in: .whitespacesAndNewlines)
    return ["name": name.isEmpty ? email : name, "org": org, "plan": plan, "email": email]
}

/// core.limits_are_fresh()
public func limitsAreFresh(_ limits: JSONObject, now: Date, maxAgeMinutes: Int = 5) -> Bool {
    guard let fetched = limits["fetched_at"] as? String, !fetched.isEmpty,
          let dt = parseDate(fetched) else { return false }
    return now.timeIntervalSince(dt) < Double(maxAgeMinutes * 60)
}

let week: TimeInterval = 7 * 86400

/// core.week_window(): (start, end, deviates) of the weekly window, or nil.
public func weekWindow(_ limits: JSONObject) -> (start: Date, end: Date, deviates: Bool)? {
    guard let end = parseDate(string(block(limits, "seven_day"), "resets_at")) else { return nil }
    let raw = block(limits, "seven_day_breakdown")["window_started_at"]
    var start: Date? = nil
    if truthy(raw), let s = raw as? String { start = parseDate(s) }
    guard let st = start, st < end else { return (end - week, end, false) }
    return (st, end, abs(end.timeIntervalSince(st) - week) > 60)
}

/// core.week_progress(): {elapsed_pct, day, days} or nil.
public func weekProgress(_ limits: JSONObject, now: Date) -> JSONObject? {
    guard let win = weekWindow(limits) else { return nil }
    let total = win.end.timeIntervalSince(win.start)
    let done = min(max(now.timeIntervalSince(win.start), 0), total)
    let days = max(1, pyRound(total / 86400))
    let day = min(days, Int((done / 86400).rounded(.down)) + 1)
    return ["elapsed_pct": pyRound1(done / total * 100), "day": day, "days": days]
}

/// core.status_badge_class(): orange for minor, red for major/critical.
public func statusBadgeClass(_ service: JSONObject?) -> String {
    switch service?["level"] as? String {
    case "minor": return "stale"
    case "major", "critical": return "disconnected"
    default: return ""
    }
}
