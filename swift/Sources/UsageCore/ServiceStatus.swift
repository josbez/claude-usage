import Foundation

// Claude service status (public Statuspage API, no login) — core.service_status().

public let statusSummaryURL = URL(string: "https://status.claude.com/api/v2/summary.json")!
public let statusCheckInterval: TimeInterval = 300

/// Documented Atlassian Statuspage values (core.STATUS_INDICATOR_LEVELS).
let statusIndicatorLevels = ["none": "ok", "minor": "minor", "major": "major", "critical": "critical"]
let statusComponentValues: Set<String> = ["operational", "degraded_performance", "partial_outage",
                                          "major_outage", "under_maintenance"]

/// core.service_status(): {level, description, issues, incidents, unknown} or nil.
public func serviceStatus(_ summary: Any?) -> JSONObject? {
    guard let s = summary as? JSONObject, let status = s["status"] as? JSONObject,
          let indicator = status["indicator"] as? String else { return nil }
    var unknown: [String] = []
    var level = statusIndicatorLevels[indicator] ?? "unknown"
    if statusIndicatorLevels[indicator] == nil {
        level = "unknown"
        unknown.append("indicator=\(indicator)")
    }
    let description = (status["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    var issues: [JSONObject] = []
    for item in s["components"] as? [Any] ?? [] {
        guard let comp = item as? JSONObject, !truthy(comp["group"]),
              let name = comp["name"] as? String, let cstatus = comp["status"] as? String,
              cstatus != "operational" else { continue }
        if !statusComponentValues.contains(cstatus) { unknown.append("component:\(name)=\(cstatus)") }
        issues.append(["name": name, "status": cstatus])
    }

    var incidents: [JSONObject] = []
    for item in s["incidents"] as? [Any] ?? [] {
        guard let inc = item as? JSONObject, let name = inc["name"] as? String else { continue }
        var url = statusPageURL
        if let id = inc["id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) {
            url = statusPageURL + "incidents/" + id
        }
        incidents.append(["name": name, "url": url])
    }
    return ["level": level, "description": description, "issues": issues,
            "incidents": incidents, "unknown": unknown]
}
