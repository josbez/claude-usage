import Foundation

/// App state that is not in the limits file (app.py keeps these on the delegate).
public struct AppState {
    public var loggedIn = true
    public var lastFetchError: String? = nil
    public var fetching = false
    public var notificationsAvailable = false
    public var version = "dev"
    public var build = ""
    public var update: JSONObject? = nil
    public var service: JSONObject? = nil

    public init() {}
}

extension UsageFormatter {
    /// app.py _build_data(): everything window.updateData() gets, as one pure function.
    public func dashboardData(limits: JSONObject, settings: JSONObject, state: AppState,
                              lang: String) -> JSONObject {
        let five = block(limits, "five_hour"), seven = block(limits, "seven_day")
        let sessionPct = pyInt(jsonNumber(five["utilization"]) ?? 0)
        let weeklyPct = pyInt(jsonNumber(seven["utilization"]) ?? 0)
        let sessionCompact = resetCompact(string(five, "resets_at"), lang)

        var lastUpdated = ""
        var ageMinutes: Double? = nil
        var fetchedHHMM = ""
        if let fetched = limits["fetched_at"] as? String, !fetched.isEmpty, let ft = parseDate(fetched) {
            let age = now.timeIntervalSince(ft) / 60
            ageMinutes = age
            fetchedHHMM = LocalParts(ft, timeZone: timeZone).hhmm
            let diff = pyInt(age)
            lastUpdated = diff < 1 ? strings.t("ago_now", lang)
                : diff == 1 ? strings.t("ago_one_min", lang)
                : strings.t("ago_min", lang, ["n": diff])
        }

        var status = "ok", reason = ""
        if !state.loggedIn {
            status = "not_logged_in"; reason = strings.t("reason_not_logged_in", lang)
        } else if state.lastFetchError != nil {
            status = "stale"
            reason = fetchedHHMM.isEmpty ? strings.t("reason_failed", lang)
                                         : strings.t("reason_failed_at", lang, ["time": fetchedHHMM])
        } else if ageMinutes == nil {
            status = "stale"; reason = strings.t("reason_not_fetched", lang)
        } else if ageMinutes! > Double(staleAfterMinutes(refresh: refreshMinutes(settings))) {
            status = "stale"
            reason = fetchedHHMM.isEmpty ? strings.t("reason_stale", lang)
                                         : strings.t("reason_data_at", lang, ["time": fetchedHHMM])
        }

        var previews: JSONObject = [:]
        let ring = settings["menubar_icon"] as? String == "ring"
        for style in menubarStyles {
            let title = statusTitle(session: sessionPct, weekly: weeklyPct,
                                    compact: sessionCompact, style: style)
            // Text preview of the ring: a circle glyph filled to the nearest quarter
            let glyph = ["○", "◔", "◑", "◕", "●"][min(4, (max(0, sessionPct) + 12) / 25)]
            let rest = titleWithoutFace(title)
            previews[style] = ring ? (rest.isEmpty ? glyph : "\(glyph) \(rest)") : title
        }
        return [
            "session_pct": sessionPct,
            "session_reset": resetTime(string(five, "resets_at"), lang),
            "session_reset_compact": sessionCompact,
            "weekly_pct": weeklyPct,
            "weekly_reset": resetTime(string(seven, "resets_at"), lang),
            "account": string(limits, "account_email"),
            "account_label": accountLabel(limits),
            "week_progress": weekProgress(limits, now: now) ?? NSNull(),
            "fetching": state.fetching,
            "last_updated": lastUpdated,
            "status": status,
            "status_reason": reason,
            "notifications_enabled": settings["notifications"] ?? true,
            "notifications_available": state.notificationsAvailable,
            "version": state.version,
            "build": state.build,
            "update": state.update ?? NSNull(),
            "limit_resets": limitResetsView(limits, lang) ?? NSNull(),
            "service": state.service ?? NSNull(),
            "service_badge": statusBadgeClass(state.service),
            "menubar_style": settings["menubar_style"] ?? "full",
            "appearance": settings["appearance"] ?? "system",
            "refresh_minutes": refreshMinutes(settings),
            "menubar_icon": settings["menubar_icon"] ?? "ring",
            "lang": lang,
            "i18n": strings.table[lang] ?? [:],
            "menubar_previews": previews,
        ]
    }
}
