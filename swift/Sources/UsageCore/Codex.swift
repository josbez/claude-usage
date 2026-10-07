import Foundation

// Codex as a usage source (taak 55c). The numbers come from `codex app-server`
// (`account/rateLimits/read`, see CodexAppServer.swift); probe 55h showed it
// returns the same values as the Codex settings, also with the ChatGPT app
// closed. Read only: never a method that spends a reset.

public let codexSource = "codex"

/// How often the app asks `codex app-server` (each call: ~2.5 s, ~77 MB while it runs).
public let codexCheckInterval: TimeInterval = 5 * 60

/// Values seen in real responses (7-10-2026). Anything else is logged, never guessed.
let codexKnownPlans: Set<String> = ["plus"]
let codexKnownResetStatuses: Set<String> = ["available"]
let codexKnownResetTypes: Set<String> = ["codexRateLimits"]

/// Where a `codex` binary may live, most likely first. The ChatGPT app bundles
/// one; a separate install puts it in a bin folder. No shell, no PATH lookup:
/// an app started at login has a minimal PATH anyway.
public func codexBinaryCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
    let bundled = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    return [
        URL(fileURLWithPath: "/Applications/ChatGPT.app").appendingPathComponent(bundled),
        home.appendingPathComponent("Applications/ChatGPT.app").appendingPathComponent(bundled),
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
        home.appendingPathComponent(".local/bin/codex"),
        home.appendingPathComponent(".npm-global/bin/codex"),
    ]
}

public func findCodexBinary(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            fm: FileManager = .default) -> URL? {
    codexBinaryCandidates(home: home).first { fm.isExecutableFile(atPath: $0.path) }
}

/// Whether to ask the app-server again.
public func codexCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = codexCheckInterval) -> Bool {
    guard let lastCheck else { return true }
    return now.timeIntervalSince(lastCheck) >= interval
}

/// A snapshot plus what in the response we didn't recognise (for the log).
public struct CodexParse {
    public let snapshot: SourceSnapshot?
    public let unknown: [String]
}

/// The `account/rateLimits/read` result as a snapshot. Never keeps the account
/// id or a credit's id/description (they are not in the snapshot at all).
public func codexSnapshot(rateLimits result: JSONObject, fetchedAt: Date, now: Date) -> CodexParse {
    var unknown: [String] = []
    let byId = result["rateLimitsByLimitId"] as? JSONObject
    guard let limits = (byId?[codexSource] as? JSONObject) ?? (result["rateLimits"] as? JSONObject) else {
        return CodexParse(snapshot: nil, unknown: ["geen rateLimits in het antwoord"])
    }

    var windows: [UsageWindow] = []
    for key in ["primary", "secondary"] {
        guard let w = limits[key] as? JSONObject else { continue }
        guard let used = jsonNumber(w["usedPercent"]), let minutes = jsonInt(w["windowDurationMins"]) else {
            unknown.append("venster \(key) zonder usedPercent/windowDurationMins")
            continue
        }
        let kind = windowKind(durationMinutes: minutes)
        if kind == .other { unknown.append("venster \(key) van \(minutes) min") }
        let resets = jsonNumber(w["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
        windows.append(UsageWindow(id: key, kind: kind, utilization: used, resetsAt: resets))
    }

    var plan: String? = nil
    if let p = limits["planType"] as? String, !p.isEmpty {
        if codexKnownPlans.contains(p) { plan = p } else { unknown.append("planType \(p)") }
    }

    let (credits, creditUnknown) = codexResetCredits(result["rateLimitResetCredits"], now: now)
    unknown += creditUnknown

    let snapshot = SourceSnapshot(
        source: UsageSource(id: codexSource, tool: "codex", accountLabel: ""),
        windows: windows, fetchedAt: fetchedAt, plan: plan, resetCredits: credits, extras: [:])
    return CodexParse(snapshot: snapshot, unknown: unknown)
}

/// Reset credits still usable: status "available" and not expired. Only known
/// statuses and types count; the rest is reported for the log.
func codexResetCredits(_ raw: Any?, now: Date) -> (ResetCredits?, [String]) {
    guard let obj = raw as? JSONObject else { return (nil, []) }
    var unknown: [String] = []
    guard let list = obj["credits"] as? [Any] else {
        // Count without details: nothing to check expiry against.
        if let n = jsonInt(obj["availableCount"]), n > 0 { return (ResetCredits(available: n, nextExpiry: nil, labels: []), []) }
        return (nil, [])
    }
    var count = 0
    var expiries: [Date] = []
    var labels: [String] = []
    for case let c as JSONObject in list {
        let status = c["status"] as? String ?? ""
        let type = c["resetType"] as? String ?? ""
        if !codexKnownResetStatuses.contains(status) {
            // Spent or expired credits are expected later; log their status once seen.
            unknown.append("reset-status \(status)")
            continue
        }
        if !codexKnownResetTypes.contains(type) {
            unknown.append("reset-type \(type)")
            continue
        }
        let expires = jsonNumber(c["expiresAt"]).map { Date(timeIntervalSince1970: $0) }
        if let e = expires, e <= now { continue }
        count += 1
        if let e = expires { expiries.append(e) }
        if let t = (c["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            labels.append(t)
        }
    }
    return (count == 0 ? nil : ResetCredits(available: count, nextExpiry: expiries.min(), labels: labels), unknown)
}

// MARK: - Snapshot file (usage-limits/<source>.json) for sources other than Claude

/// The Claude source keeps its raw API file; other sources store this format.
public func snapshotJSON(_ s: SourceSnapshot) -> JSONObject {
    func iso(_ d: Date?) -> Any { d.map { isoString($0) } ?? NSNull() }
    var out: JSONObject = [
        "source": s.source.id, "tool": s.source.tool,
        "fetched_at": iso(s.fetchedAt), "plan": s.plan ?? NSNull(),
        "windows": s.windows.map { ["id": $0.id, "kind": $0.kind.rawValue,
                                    "utilization": $0.utilization, "resets_at": iso($0.resetsAt)] },
    ]
    if let c = s.resetCredits {
        out["reset_credits"] = ["available": c.available, "next_expiry": iso(c.nextExpiry), "labels": c.labels]
    }
    return out
}

/// Reads snapshotJSON back; nil when the file isn't one (or is for another source).
public func snapshot(fromJSON obj: JSONObject, sourceId: String) -> SourceSnapshot? {
    guard obj["source"] as? String == sourceId, let tool = obj["tool"] as? String,
          let rawWindows = obj["windows"] as? [Any] else { return nil }
    var windows: [UsageWindow] = []
    for case let w as JSONObject in rawWindows {
        guard let id = w["id"] as? String, let kind = WindowKind(rawValue: w["kind"] as? String ?? ""),
              let u = jsonNumber(w["utilization"]) else { continue }
        windows.append(UsageWindow(id: id, kind: kind, utilization: u,
                                   resetsAt: (w["resets_at"] as? String).flatMap(parseDate)))
    }
    var credits: ResetCredits? = nil
    if let c = obj["reset_credits"] as? JSONObject, let n = jsonInt(c["available"]) {
        credits = ResetCredits(available: n, nextExpiry: (c["next_expiry"] as? String).flatMap(parseDate),
                               labels: c["labels"] as? [String] ?? [])
    }
    return SourceSnapshot(source: UsageSource(id: sourceId, tool: tool, accountLabel: ""),
                          windows: windows, fetchedAt: (obj["fetched_at"] as? String).flatMap(parseDate),
                          plan: obj["plan"] as? String, resetCredits: credits, extras: [:])
}
