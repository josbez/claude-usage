import Foundation

// Notifications and history per source (taak 55g, pure part). Same rules as
// the Claude notifications (Notifications.swift): thresholds per window, at
// most one notification per window per fetch, state per window, a "has
// reset" notification after a warned window rolls over.
//
// State keys are "<state key>|five_hour" and "<state key>|seven_day", the
// format the Claude notifications already use with the account e-mail as
// state key. So Claude can move onto this path later without a migration
// (and without anyone getting the 80% notification again); other sources
// use their source id ("codex|five_hour").
//
// Text is not made here: the titles in strings.json still start with
// "Claude:". The app turns a SourceAlert into text with the source's name.

/// A snapshot older than this gives no notifications: it says what was true
/// back then (e.g. the Codex session-file fallback), not now.
public let sourceAlertMaxAge: TimeInterval = 30 * 60

public struct SourceAlert: Equatable {
    public let id: String
    public let sourceId: String
    public let window: WindowKind
    /// The threshold crossed; nil for a "limit has reset" notification.
    public let threshold: Int?
    public let pct: Int
    public let resetsAt: Date?
    public var isReset: Bool { threshold == nil }
}

/// The state key part per window kind: the names Claude's state already uses.
func alertLimitName(_ kind: WindowKind) -> String? {
    switch kind {
    case .session: return "five_hour"
    case .weekly: return "seven_day"
    case .other: return nil
    }
}

/// Notifications due for one source: (alerts, new state). `stateKey` is the
/// account e-mail for Claude, the source id for other sources.
public func dueSourceAlerts(_ snapshot: SourceSnapshot, stateKey: String, state: JSONObject, now: Date,
                            session: [Int] = fiveHourThresholds, weekly: [Int] = weeklyThresholds,
                            maxAge: TimeInterval = sourceAlertMaxAge) -> ([SourceAlert], JSONObject) {
    guard let fetched = snapshot.fetchedAt, now.timeIntervalSince(fetched) <= maxAge else { return ([], state) }
    var newState = state
    var alerts: [SourceAlert] = []
    for (kind, thresholds) in [(WindowKind.session, session), (.weekly, weekly)] {
        guard let w = snapshot.window(kind), let limit = alertLimitName(kind),
              let resets = w.resetsAt else { continue }
        let wk = windowKey(isoString(resets))
        if wk.isEmpty { continue }
        let pct = pyInt(w.utilization)
        let key = "\(stateKey)|\(limit)"
        let entry = state[key] as? JSONObject ?? [:]
        let entryWindow = entry["window"] as? String
        let entrySent = (entry["sent"] as? [Any] ?? []).compactMap { jsonInt($0) ?? ($0 as? Int) }
        var sent = entryWindow == wk ? entrySent : []
        let crossed = thresholds.filter { pct >= $0 && !sent.contains($0) }
        if crossed.isEmpty, truthy(entry["sent"]), let from = entryWindow, !from.isEmpty, from < wk,
           let old = parseDate(from), now.timeIntervalSince(old) <= resetNotifyMaxAge {
            alerts.append(SourceAlert(id: "\(key)|\(wk)|reset", sourceId: snapshot.source.id, window: kind,
                                      threshold: nil, pct: pct, resetsAt: resets))
        }
        if let top = crossed.max() {
            alerts.append(SourceAlert(id: "\(key)|\(wk)|\(top)", sourceId: snapshot.source.id, window: kind,
                                      threshold: top, pct: pct, resetsAt: resets))
            sent = Array(Set(sent).union(crossed)).sorted()
        }
        newState[key] = ["window": wk, "sent": sent]
    }
    return (alerts, newState)
}

// MARK: - History per source

/// History folder of a source. Claude keeps the existing usage-history/
/// (no migration, trends (40) reads it as is); other sources get a subfolder.
public func historyDir(for sourceId: String, paths: Paths) -> URL {
    sourceId == claudeDesktopSource ? paths.historyDir : paths.historyDir.appendingPathComponent(sourceId)
}

/// One history line for a non-Claude source: only what the source reported
/// (Claude keeps historyRecord(limits) with its raw API values).
public func sourceHistoryRecord(_ s: SourceSnapshot) -> JSONObject? {
    guard let fetched = s.fetchedAt else { return nil }
    var rec: JSONObject = ["ts": isoString(fetched), "source": s.source.id]
    for w in s.windows {
        guard let name = alertLimitName(w.kind) else { continue }
        var entry: JSONObject = ["utilization": w.utilization]
        if let r = w.resetsAt { entry["resets_at"] = isoString(r) }
        rec[name] = entry
    }
    if let plan = s.plan { rec["plan"] = plan }
    if let c = s.resetCredits { rec["reset_credits"] = c.available }
    return rec
}

/// Whether a snapshot is new enough to record: the session-file fallback can
/// return the same event several times.
public func isNewHistoryRecord(_ s: SourceSnapshot, lastRecorded: Date?) -> Bool {
    guard let fetched = s.fetchedAt else { return false }
    guard let last = lastRecorded else { return true }
    return fetched > last
}
