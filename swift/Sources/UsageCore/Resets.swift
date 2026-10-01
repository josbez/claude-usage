import Foundation

public let resetsURL = "https://claude.ai/settings/usage"
public let statusPageURL = "https://status.claude.com/"

func grants(_ limits: JSONObject) -> [JSONObject]? {
    guard let ce = limits["cedar_ember"] as? JSONObject, let list = ce["grants"] as? [Any]
    else { return nil }
    return list.compactMap { $0 as? JSONObject }
}

/// core.limit_resets(): free limit resets usable on claude.ai, or nil.
public func limitResets(_ limits: JSONObject, now: Date) -> (count: Int, endsAt: Date?, labels: [String])? {
    guard let list = grants(limits) else { return nil }
    let ce = limits["cedar_ember"] as! JSONObject
    if isJSONBool(ce["eligible"]), (ce["eligible"] as! NSNumber).boolValue == false { return nil }
    var count = 0
    var ends: [Date] = []
    var labels: [String] = []
    for g in list {
        guard let left = jsonInt(g["resets_left"]), left > 0 else { continue }
        if isJSONBool(g["paused"]), (g["paused"] as! NSNumber).boolValue { continue }
        if truthy(g["starts_at"]) {
            guard let s = g["starts_at"] as? String, let start = parseDate(s) else { continue }
            if start > now { continue }
        }
        var end: Date? = nil
        if truthy(g["ends_at"]) {
            guard let s = g["ends_at"] as? String, let e = parseDate(s) else { continue }
            end = e
        }
        if let e = end, e <= now { continue }
        count += left
        if let e = end { ends.append(e) }
        if let label = g["label"] as? String {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { labels.append(trimmed) }
        }
    }
    return count == 0 ? nil : (count, ends.min(), labels)
}

extension UsageFormatter {
    /// core.limit_resets_view(): what the popover shows under the session ring.
    public func limitResetsView(_ limits: JSONObject, _ lang: String) -> [String: String]? {
        guard let info = limitResets(limits, now: now) else { return nil }
        var text = info.count == 1 ? strings.t("resets_one", lang)
                                   : strings.t("resets_many", lang, ["n": info.count])
        if let end = info.endsAt {
            let date = shortDate(isoString(end), lang)
            if !date.isEmpty { text += strings.t("resets_until", lang, ["date": date]) }
        }
        let tip = info.labels.joined(separator: " · ")
        return ["text": text, "tip": (tip.isEmpty ? "" : tip + " — ") + strings.t("resets_open", lang),
                "url": resetsURL]
    }
}

func isoString(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

public func isStatusURL(_ url: String) -> Bool { url.hasPrefix(statusPageURL) }
