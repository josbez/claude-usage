import Foundation

// Usage history: the API only returns the current state, so we keep our own
// record (source for the trends tab). Raw API values only — no derived data.
// core.py: history_record, history_path, append_history.

/// core.history_record(): one history line from a fetched limits dict.
public func historyRecord(_ limits: JSONObject) -> JSONObject {
    var rec: JSONObject = [:]
    func set(_ key: String, _ value: Any?) {
        if let v = value, !(v is NSNull) { rec[key] = v }
    }
    set("ts", limits["fetched_at"])
    set("account", limits["account_email"])
    set("org_id", limits["org_id"])
    set("five_hour", pick(limits["five_hour"], ["utilization", "resets_at"]))
    set("seven_day", pick(limits["seven_day"], ["utilization", "resets_at"]))
    if let bd = limits["seven_day_breakdown"] as? JSONObject {
        let rows = (bd["rows"] as? [Any] ?? []).compactMap { $0 as? JSONObject }
            .compactMap { pick($0, ["key", "display_name", "percent"]) }
        var inner: JSONObject = ["window_started_at": bd["window_started_at"] ?? NSNull()]
        inner["rows"] = rows.isEmpty ? NSNull() : rows
        set("breakdown", pick(inner, ["window_started_at", "rows"]))
    }
    if let extra = limits["extra_usage"] as? JSONObject, truthy(extra["is_enabled"]) {
        set("extra_usage", pick(extra, ["used_credits", "monthly_limit", "currency"]))
    }
    set("cedar_ember", cedarEmberStable(limits))
    return rec
}

/// core.history_path(): monthly file (UTC) for a record timestamp: <base>/YYYY-MM.jsonl.
public func historyPath(_ ts: String, base: URL) -> URL? {
    guard let dt = parseDate(ts) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let c = cal.dateComponents([.year, .month], from: dt)
    return base.appendingPathComponent(String(format: "%04d-%02d.jsonl", c.year!, c.month!))
}

/// core.append_history(): append one compact JSON line; throws on I/O errors —
/// the caller logs and carries on. Keys are sorted (Python keeps API order);
/// readers parse JSON, so only the byte order differs.
@discardableResult
public func appendHistory(_ record: JSONObject, base: URL) throws -> URL {
    guard let ts = record["ts"] as? String, let path = historyPath(ts, base: base) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    var line = try JSONSerialization.data(withJSONObject: record,
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    line.append(0x0A)
    if let h = try? FileHandle(forWritingTo: path) {
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    } else {
        try line.write(to: path)
    }
    return path
}
