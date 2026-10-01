import Foundation

/// Formatting from core.py. `now` and `timeZone` are parameters (core.py reads
/// the clock and the local zone itself) so tests can pin them.
public struct UsageFormatter {
    public let strings: Strings
    public let now: Date
    public let timeZone: TimeZone

    public init(strings: Strings, now: Date = Date(), timeZone: TimeZone = .current) {
        self.strings = strings
        self.now = now
        self.timeZone = timeZone
    }

    /// core.format_reset_time(): "in 2h 15m" within a day, else "Thu 14:00".
    public func resetTime(_ iso: String, _ lang: String) -> String {
        guard !iso.isEmpty, let dt = parseDate(iso) else { return "—" }
        let total = pyInt(dt.timeIntervalSince(now))
        if total > 0 && total < 86400 {
            let h = total / 3600, m = (total % 3600) / 60
            return h > 0 ? strings.t("in_hm", lang, ["h": h, "m": m])
                         : strings.t("in_m", lang, ["m": m])
        }
        let p = LocalParts(dt, timeZone: timeZone)
        return "\(strings.dayNames(lang)[p.weekdayMonday0]) \(p.hhmm)"
    }

    /// core.format_reset_compact(): "2u15m" / "2h15m" or "45m" for the menu bar.
    public func resetCompact(_ iso: String, _ lang: String) -> String {
        guard !iso.isEmpty, let dt = parseDate(iso) else { return "—" }
        let total = pyInt(dt.timeIntervalSince(now))
        if total <= 0 { return "—" }
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? strings.t("compact_hm", lang, ["h": h, "m": m])
                     : strings.t("compact_m", lang, ["m": m])
    }

    /// core.format_short_date(): "do 22 okt" / "Thu Oct 22"; "" when unparseable.
    public func shortDate(_ iso: String, _ lang: String) -> String {
        guard let dt = parseDate(iso) else { return "" }
        let p = LocalParts(dt, timeZone: timeZone)
        let day = strings.dayNames(lang)[p.weekdayMonday0]
        let mon = strings.monthNames(lang)[p.month - 1]
        return lang == "nl" ? "\(day) \(p.day) \(mon)" : "\(day) \(mon) \(p.day)"
    }

    /// core.title_from_limits()
    public func titleFromLimits(_ limits: JSONObject, style: String, lang: String) -> String {
        let five = block(limits, "five_hour"), seven = block(limits, "seven_day")
        return statusTitle(session: pyInt(jsonNumber(five["utilization"]) ?? 0),
                           weekly: pyInt(jsonNumber(seven["utilization"]) ?? 0),
                           compact: resetCompact(string(five, "resets_at"), lang),
                           style: style)
    }
}

/// core.face_icon(): stresses out as the session fills up.
public func faceIcon(_ pct: Int) -> String {
    switch pct {
    case 100...: return "💀"
    case 90...: return "😱"
    case 75...: return "😰"
    case 60...: return "😨"
    case 40...: return "😅"
    case 20...: return "🙂"
    default: return "🚀"
    }
}

public let menubarStyles = ["full", "session", "emoji"]
public let appearanceStyles = ["system", "light", "dark"]

/// core.status_title(): 'full': 😅 45% / 82% · 2u10m, 'session': 😅 45%, 'emoji': 😅.
public func statusTitle(session: Int, weekly: Int, compact: String, style: String) -> String {
    let face = faceIcon(session)
    switch style {
    case "emoji": return face
    case "session": return "\(face) \(session)%"
    default: return "\(face) \(session)% / \(weekly)% · \(compact)"
    }
}
