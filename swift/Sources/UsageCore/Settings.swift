import Foundation

/// Where the app keeps its files. The Python app and the released Swift app share
/// the same paths (same formats, so an update keeps settings and history).
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

    public var limits: URL { own("usage-limits", ext: "json") }
    public var blockLogState: URL { own("usage-tracker-blocks", ext: "json") }
    public var settings: URL { own("usage-tracker-settings", ext: "json") }
    public var notifyState: URL { own("usage-tracker-notified", ext: "json") }
    public var updateState: URL { own("usage-tracker-update", ext: "json") }
    public var historyDir: URL { claudeDir.appendingPathComponent(isDev ? "usage-history-dev" : "usage-history") }
    public var log: URL {
        home.appendingPathComponent("Library/Logs")
            .appendingPathComponent(isDev ? "ClaudeUsage-Dev.log" : "ClaudeUsage.log")
    }
}

public let defaultSettings: JSONObject = [
    "notifications": true, "update_check": true, "menubar_style": "full", "appearance": "system",
]

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
    return settings
}

public func loadSettings(_ url: URL) -> JSONObject {
    normalizeSettings(loadJSONObject(url))
}

public func saveSettings(_ settings: JSONObject, _ url: URL) throws {
    try saveJSONObject(settings, to: url)
}
