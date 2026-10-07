import Foundation

// One format for every usage source (taak 55b): Claude now, Codex (55c) and a
// second Claude account (43b) later. Only the format and the Claude
// conversion live here; the popover, menu bar, notifications and history
// still read the Claude limits file directly until 55d/55f/55g switch over.

public enum WindowKind: String, Equatable {
    case session, weekly, other
}

/// A limit window as the source reports it. `utilization` is 0–100.
public struct UsageWindow: Equatable {
    /// The source's own key for this window ("five_hour", "primary", …).
    public let id: String
    public let kind: WindowKind
    public let utilization: Double
    public let resetsAt: Date?

    public init(id: String, kind: WindowKind, utilization: Double, resetsAt: Date?) {
        self.id = id; self.kind = kind; self.utilization = utilization; self.resetsAt = resetsAt
    }
}

/// Free limit resets the user can spend in the tool itself (read-only for us).
public struct ResetCredits: Equatable {
    public let available: Int
    /// When the first of them expires, if the source says.
    public let nextExpiry: Date?
    public let labels: [String]

    public init(available: Int, nextExpiry: Date?, labels: [String]) {
        self.available = available; self.nextExpiry = nextExpiry; self.labels = labels
    }
}

/// Where the numbers come from. `id` is stable and never holds personal data
/// (it ends up in file names); `accountLabel` is for display only.
public struct UsageSource: Equatable, Hashable {
    public let id: String
    public let tool: String
    public let accountLabel: String

    public init(id: String, tool: String, accountLabel: String) {
        self.id = id; self.tool = tool; self.accountLabel = accountLabel
    }
}

/// One source's numbers at one moment.
public struct SourceSnapshot {
    public let source: UsageSource
    /// Only windows the source actually reported; a missing one is absent, not 0.
    public let windows: [UsageWindow]
    /// When the numbers were fetched (or, for a snapshot file, written).
    public let fetchedAt: Date?
    public let plan: String?
    public let resetCredits: ResetCredits?
    /// Source-specific data the shared views don't know (Claude: the raw
    /// limits with product breakdown, extra usage, cedar_ember, …).
    public let extras: JSONObject

    public init(source: UsageSource, windows: [UsageWindow], fetchedAt: Date?, plan: String?,
                resetCredits: ResetCredits?, extras: JSONObject) {
        self.source = source; self.windows = windows; self.fetchedAt = fetchedAt
        self.plan = plan; self.resetCredits = resetCredits; self.extras = extras
    }

    public func window(_ kind: WindowKind) -> UsageWindow? { windows.first { $0.kind == kind } }
}

/// Window kind from its length, for sources that report minutes (Codex: 300
/// and 10080). Anything else is `.other`: never guessed.
public func windowKind(durationMinutes: Int) -> WindowKind {
    switch durationMinutes {
    case 300: return .session
    case 10080: return .weekly
    default: return .other
    }
}

public let claudeDesktopSource = "claude-desktop"

/// Claude's per-model weekly windows: reported only for some plans, mostly null.
let claudeOtherWindowKeys = ["seven_day_opus", "seven_day_sonnet", "seven_day_cowork",
                             "seven_day_oauth_apps", "seven_day_omelette"]

/// The Claude limits file (usage-limits.json) as a snapshot.
public func claudeSnapshot(limits: JSONObject, now: Date) -> SourceSnapshot {
    func window(_ key: String, _ kind: WindowKind) -> UsageWindow? {
        guard let b = limits[key] as? JSONObject, let u = jsonNumber(b["utilization"]) else { return nil }
        return UsageWindow(id: key, kind: kind, utilization: u, resetsAt: parseDate(string(b, "resets_at")))
    }
    var windows = [window("five_hour", .session), window("seven_day", .weekly)].compactMap { $0 }
    windows += claudeOtherWindowKeys.compactMap { window($0, .other) }

    let label = accountLabel(limits)
    let plan = label["plan"] ?? ""
    let credits = limitResets(limits, now: now).map {
        ResetCredits(available: $0.count, nextExpiry: $0.endsAt, labels: $0.labels)
    }
    return SourceSnapshot(
        source: UsageSource(id: claudeDesktopSource, tool: "claude", accountLabel: label["name"] ?? ""),
        windows: windows,
        fetchedAt: parseDate(string(limits, "fetched_at")),
        plan: plan.isEmpty ? nil : plan,
        resetCredits: credits,
        extras: limits)
}
