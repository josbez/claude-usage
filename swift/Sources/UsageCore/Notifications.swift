import Foundation

// Limit notifications: which thresholds to announce (core.py: window_key,
// due_notifications, color_for_pct). Posting lives in the app.

public let fiveHourThresholds = [80, 95]
public let weeklyThresholds = [90]
/// A reset is only announced if the old window ended recently: after days with
/// the app closed, "limit has reset" would just be noise.
let resetNotifyMaxAge: TimeInterval = 12 * 3600

/// core.window_key(): stable id for one limit window. resets_at jitters by a few
/// microseconds between fetches, so round to the minute (UTC).
public func windowKey(_ resetsAt: String) -> String {
    guard !resetsAt.isEmpty, let dt = parseDate(resetsAt) else { return "" }
    let rounded = Date(timeIntervalSince1970: ((dt.timeIntervalSince1970 + 30) / 60).rounded(.down) * 60)
    return pyIsoformatUTC(rounded)
}

public struct LimitNotification {
    public let id: String
    public let title: String
    public let body: String
    public let limit: String
    public let threshold: Int?
    public let pct: Int
    public let isReset: Bool

    /// The same dict core.due_notifications() returns (for tests and logging).
    public var asJSON: JSONObject {
        var d: JSONObject = ["id": id, "title": title, "body": body, "limit": limit,
                             "threshold": threshold.map { $0 as Any } ?? NSNull(), "pct": pct]
        if isReset { d["kind"] = "reset" }
        return d
    }
}

extension UsageFormatter {
    /// core.due_notifications(): (notifications, new state).
    ///
    /// One notification per limit per fetch at most: if several thresholds were
    /// crossed at once only the highest is announced, but all are marked sent.
    /// State is keyed per account and per limit, and resets when the window
    /// changes. After a window change following a warning, a "limit has reset"
    /// notification follows (unless a new threshold is already crossed).
    public func dueNotifications(_ limits: JSONObject, state: JSONObject, lang: String,
                                 fiveHour: [Int] = fiveHourThresholds,
                                 weekly: [Int] = weeklyThresholds) -> ([LimitNotification], JSONObject) {
        let account = string(limits, "account_email")
        var newState = state
        var notes: [LimitNotification] = []
        for (limit, thresholds) in [("five_hour", fiveHour), ("seven_day", weekly)] {
            let b = block(limits, limit)
            let wk = windowKey(string(b, "resets_at"))
            if wk.isEmpty { continue }
            let pct = pyInt(jsonNumber(b["utilization"]) ?? 0)
            let key = "\(account)|\(limit)"
            let entry = state[key] as? JSONObject ?? [:]
            let entryWindow = entry["window"] as? String
            let entrySent = (entry["sent"] as? [Any] ?? []).compactMap { jsonInt($0) ?? ($0 as? Int) }
            var sent = entryWindow == wk ? entrySent : []
            let crossed = thresholds.filter { pct >= $0 && !sent.contains($0) }
            var resetFrom: String? = nil
            if truthy(entry["sent"]), let w = entryWindow, !w.isEmpty, w < wk { resetFrom = w }
            let limitName = strings.t("limit_\(limit)", lang)
            if crossed.isEmpty, let from = resetFrom, let old = parseDate(from),
               now.timeIntervalSince(old) <= resetNotifyMaxAge {
                notes.append(LimitNotification(
                    id: "\(key)|\(wk)|reset",
                    title: strings.t("notif_reset_title", lang, ["limit": limitName]),
                    body: strings.t("notif_reset_body", lang, ["pct": pct]),
                    limit: limit, threshold: nil, pct: pct, isReset: true))
            }
            if let top = crossed.max() {
                notes.append(LimitNotification(
                    id: "\(key)|\(wk)|\(top)",
                    title: strings.t("notif_limit_title", lang, ["limit": limitName, "pct": pct]),
                    body: strings.t("notif_limit_body", lang,
                                    ["when": resetTime(string(b, "resets_at"), lang)]),
                    limit: limit, threshold: top, pct: pct, isReset: false))
                sent = Array(Set(sent).union(crossed)).sorted()
            }
            newState[key] = ["window": wk, "sent": sent]
        }
        return (notes, newState)
    }
}

/// core.color_for_pct(): green -> orange -> red, like colorForPct() in dashboard.html.
public func colorForPct(_ pct: Double) -> (Int, Int, Int) {
    let p = max(0, min(100, pct))
    let (p0, c0, p1, c1): (Double, [Double], Double, [Double]) = p <= 50
        ? (0, [47, 168, 74], 50, [255, 149, 0])
        : (50, [255, 149, 0], 100, [255, 59, 48])
    let t = (p - p0) / (p1 - p0)
    // floor(x + 0.5) == JS Math.round
    let c = zip(c0, c1).map { Int(($0 + ($1 - $0) * t + 0.5).rounded(.down)) }
    return (c[0], c[1], c[2])
}
