import Foundation

/// Where the app keeps its files (same names and formats across versions, so an
/// update keeps settings and history).
/// The dev build (`ClaudeUsage Dev.app`, runs next to the released app) writes to
/// its own files so both apps can be tested side by side without interfering.
public struct Paths {
    public let isDev: Bool
    public let home: URL

    public init(isDev: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.isDev = isDev
        self.home = home
    }

    var claudeDir: URL { home.appendingPathComponent(".claude") }
    private func own(_ name: String, ext: String) -> URL {
        claudeDir.appendingPathComponent(isDev ? "\(name).dev.\(ext)" : "\(name).\(ext)")
    }

    /// One file per usage source (taak 55d): `usage-limits/<source id>.json`.
    public var sourcesDir: URL { claudeDir.appendingPathComponent(isDev ? "usage-limits-dev" : "usage-limits") }
    public func snapshotFile(_ sourceId: String) -> URL {
        precondition(isValidSourceId(sourceId), "bron-id \(sourceId)")
        return sourcesDir.appendingPathComponent("\(sourceId).json")
    }
    /// The Claude desktop source: what the app fetched into usage-limits.json before 55d.
    public var limits: URL { snapshotFile(claudeDesktopSource) }
    /// usage-limits.json up to 2.1; only read once to migrate (and written by an older
    /// version after a downgrade).
    public var legacyLimits: URL { own("usage-limits", ext: "json") }
    public var blockLogState: URL { own("usage-tracker-blocks", ext: "json") }
    public var settings: URL { own("usage-tracker-settings", ext: "json") }
    public var notifyState: URL { own("usage-tracker-notified", ext: "json") }
    public var updateState: URL { own("usage-tracker-update", ext: "json") }
    public var historyDir: URL { claudeDir.appendingPathComponent(isDev ? "usage-history-dev" : "usage-history") }
    public var log: URL {
        home.appendingPathComponent("Library/Logs")
            .appendingPathComponent(isDev ? "ClaudeUsage-Dev.log" : "ClaudeUsage.log")
    }

    /// Login item written by install.sh. The dev build has none.
    public static let launchAgentLabel = "com.jos.claude-usage"
    public var launchAgent: URL? {
        isDev ? nil : home.appendingPathComponent("Library/LaunchAgents/\(Self.launchAgentLabel).plist")
    }

    /// Files "Uninstall…" removes (taak 38): exactly these paths, never a glob, so
    /// the dev build can't touch the released app's files and nothing else in
    /// ~/.claude (that belongs to Claude Code) is ever removed.
    public func uninstallTargets(keepHistory: Bool) -> [URL] {
        var urls = [sourcesDir, legacyLimits, blockLogState, settings, notifyState, updateState]
        if !keepHistory { urls.append(historyDir) }
        urls.append(log)
        return urls
    }
}

/// Source ids end up in file names: lowercase letters, digits and dashes only.
public func isValidSourceId(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
}

public enum LimitsMigration: Equatable {
    /// Nothing to do: no old file.
    case none
    /// usage-limits.json moved to usage-limits/claude-desktop.json.
    case moved
    /// Both existed (after a downgrade and update): the newer one stays.
    case keptNewer(fromLegacy: Bool)
    case failed(String)
}

/// Moves usage-limits.json into usage-limits/ (taak 55d). Idempotent; when both
/// exist the newer file wins, so going back to 2.1 and updating again loses nothing.
public func migrateLimitsFile(_ paths: Paths, fm: FileManager = .default) -> LimitsMigration {
    let old = paths.legacyLimits, new = paths.limits
    guard fm.fileExists(atPath: old.path) else { return .none }
    do {
        try fm.createDirectory(at: paths.sourcesDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: new.path) {
            func mtime(_ u: URL) -> Date {
                (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date ?? .distantPast
            }
            let legacyNewer = mtime(old) > mtime(new)
            if legacyNewer {
                try fm.removeItem(at: new)
                try fm.moveItem(at: old, to: new)
            } else {
                try fm.removeItem(at: old)
            }
            return .keptNewer(fromLegacy: legacyNewer)
        }
        try fm.moveItem(at: old, to: new)
        return .moved
    } catch {
        return .failed("\(error)")
    }
}

public let defaultSettings: JSONObject = [
    "notifications": true, "update_check": true, "menubar_style": "full", "appearance": "system",
    "refresh_minutes": 5, "menubar_icon": "ring", "seasonal_faces": true,
    "hidden_sources": [String](),
]

/// Menu bar icon (taak 49): the face emoji, or a ring that fills with the session.
public let menubarIcons = ["emoji", "ring"]

/// The ring in the menu bar: monochrome (template, like the other menu bar
/// icons) below 75%, the popover's stress colour from 75% on — the same
/// threshold as elsewhere (docs/drempels.md).
public struct MenubarRing: Equatable {
    public let fraction: Double          // 0...1 of the circle filled
    public let rgb: (Int, Int, Int)?     // nil = template (monochrome)
    public static func == (a: Self, b: Self) -> Bool {
        a.fraction == b.fraction && a.rgb.map { [$0.0, $0.1, $0.2] } == b.rgb.map { [$0.0, $0.1, $0.2] }
    }
}

public func menubarRing(sessionPct: Int) -> MenubarRing {
    let p = max(0, min(100, sessionPct))
    return MenubarRing(fraction: Double(p) / 100, rgb: p >= 75 ? colorForPct(Double(p)) : nil)
}

/// Session percentage as the menu bar shows it.
public func sessionPct(_ limits: JSONObject) -> Int {
    pyInt(jsonNumber(block(limits, "five_hour")["utilization"]) ?? 0)
}

/// The text next to the ring: the status title without its leading face.
public func titleWithoutFace(_ title: String) -> String {
    let parts = title.split(separator: " ", maxSplits: 1)
    return parts.count > 1 ? String(parts[1]) : ""
}

/// Minutes between fetches the user can pick (core.REFRESH_CHOICES, taak 51).
public let refreshChoices = [1, 5, 15]

/// The fetch interval from (normalized) settings.
public func refreshMinutes(_ settings: JSONObject) -> Int {
    jsonInt(settings["refresh_minutes"]).flatMap { refreshChoices.contains($0) ? $0 : nil } ?? 5
}

/// Data counts as stale ("verouderd") after missing about three fetches,
/// never sooner than the 15 minutes it always was.
public func staleAfterMinutes(refresh: Int) -> Int { max(15, 3 * refresh) }

/// core.load_settings(): defaults, overlaid with known stored keys; invalid
/// style/appearance values fall back to the default.
public func normalizeSettings(_ stored: Any?) -> JSONObject {
    var settings = defaultSettings
    if let stored = stored as? JSONObject {
        for (k, v) in stored where defaultSettings[k] != nil { settings[k] = v }
    }
    if !menubarStyles.contains(settings["menubar_style"] as? String ?? "") {
        settings["menubar_style"] = defaultSettings["menubar_style"]
    }
    if !appearanceStyles.contains(settings["appearance"] as? String ?? "") {
        settings["appearance"] = defaultSettings["appearance"]
    }
    if !menubarIcons.contains(settings["menubar_icon"] as? String ?? "") {
        settings["menubar_icon"] = defaultSettings["menubar_icon"]
    }
    if !isJSONBool(settings["seasonal_faces"]) { settings["seasonal_faces"] = defaultSettings["seasonal_faces"] }
    if jsonInt(settings["refresh_minutes"]).map({ !refreshChoices.contains($0) }) ?? true {
        settings["refresh_minutes"] = defaultSettings["refresh_minutes"]
    }
    // Source ids only (taak 55f); anything else is dropped
    settings["hidden_sources"] = (settings["hidden_sources"] as? [Any] ?? [])
        .compactMap { $0 as? String }.filter(isValidSourceId)
    return settings
}

public func loadSettings(_ url: URL) -> JSONObject {
    normalizeSettings(loadJSONObject(url))
}

public func saveSettings(_ settings: JSONObject, _ url: URL) throws {
    try saveJSONObject(settings, to: url)
}
