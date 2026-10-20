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
                              lang: String, others: [SourceSnapshot] = []) -> JSONObject {
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
            lastUpdated = ageText(ft, lang)
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
        let theme = faceTheme(settings)
        for style in menubarStyles {
            let title = statusTitle(session: sessionPct, weekly: weeklyPct,
                                    compact: sessionCompact, style: style, theme: theme)
            // Ring mode: the popover draws the ring itself (menubar_ring), then this text
            previews[style] = ring ? titleWithoutFace(title) : title
        }
        // Sources (taak 55f): one card each; the menu bar shows the tightest.
        let claude = claudeSnapshot(limits: limits, now: now)
        let hidden = hiddenSources(settings)
        let available = availableSources(claude: claude, others: others, now: now, hidden: hidden)
        let visible = visibleSources(available, hidden: hidden)
        var cards = visible.map { s in
            sourceCard(s, settings: settings, lang: lang,
                       claudeLimits: usesClaudeFormat(s) ? s.extras : nil)
        }
        // No source at all: one empty card that names no tool (the app is model agnostic)
        if cards.isEmpty { cards = [emptySourceCard(state: state, lang: lang)] }
        let rows: [JSONObject] = available.map { s in
            ["id": s.source.id, "name": sourceName(s, lang), "hidden": hidden.contains(s.source.id),
             "claude": s.source.id == claudeDesktopSource,
             "status": s.source.id == claudeDesktopSource ? "" : sourceStatus(s, lang: lang),
             // Claude's service status applies to every Claude tool
             "service": usesClaudeFormat(s),
             "live": ["app-server", "oauth"].contains(s.extras["origin"] as? String ?? "")]
        }
        let limited = visible.filter(hasLimits)
        let tight = tightestSource(limited, now: now) ?? claude
        if limited.isEmpty {
            // No numbers from any source: "—", never a made-up 0%
            for style in menubarStyles { previews[style] = noDataTitle }
        } else if usesSourceTitle(available) {
            // Previews follow the source the menu bar shows
            for style in menubarStyles {
                let title = sourceTitle(tight, style: style, lang: lang, theme: theme)
                previews[style] = ring ? titleWithoutFace(title) : title
            }
        }
        // Only ChatGPT: Claude never had numbers, so it has no status here. The
        // footer's age is the shown source's, and only while its card doesn't
        // say "Updated" itself.
        // Nothing found: the empty card says so; "log in to Claude" would name one tool
        if available.isEmpty && !state.loggedIn { status = "ok"; reason = "" }
        let noClaude = claudeAbsent(available)
        // Claude switched off: not fetched (taak 43b), so its old numbers are no warning
        if !noClaude && !visible.contains(where: { $0.source.id == claudeDesktopSource }) {
            status = "ok"; reason = ""
        }
        if noClaude {
            status = "ok"; reason = ""
            let card = cards.first { $0["id"] as? String == tight.source.id }
            let fresh = card.map { $0["updated"] is NSNull } ?? false
            lastUpdated = fresh ? tight.fetchedAt.map { ageText($0, lang) } ?? "" : ""
        }
        // A Claude outage is no reason for a badge when Claude isn't there
        let serviceBadge = noClaude ? "" : statusBadgeClass(state.service)
        let mr = menubarRing(sessionPct: limited.isEmpty ? 0
                             : usesSourceTitle(available) ? sourceSessionPct(tight) : sessionPct)
        var ringData: JSONObject = ["fraction": mr.fraction]
        if let (r, g, b) = mr.rgb { ringData["color"] = "rgb(\(r), \(g), \(b))" }
        return [
            "session_pct": sessionPct,
            "session_face": faceIcon(sessionPct, theme: theme),
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
            "service_badge": serviceBadge,
            "claude_absent": noClaude,
            "menubar_style": settings["menubar_style"] ?? "full",
            "appearance": settings["appearance"] ?? "system",
            "refresh_minutes": refreshMinutes(settings),
            "menubar_icon": settings["menubar_icon"] ?? "ring",
            "menubar_ring": ringData,
            // Set while a theme's window is open, also when switched off (the switch stays visible)
            "season_theme": activeFaceTheme(now, timeZone: timeZone).map { theme -> JSONObject in
                ["id": theme.id, "faces": theme.faces.joined(separator: " ")]
            } ?? NSNull(),
            "seasonal_faces": settings["seasonal_faces"] ?? true,
            "lang": lang,
            "i18n": strings.table[lang] ?? [:],
            "menubar_previews": previews,
            "sources": cards,
            // Always, also with one source: its model screen shows the status (taak 65);
            // the page offers the show switch only with two or more
            "source_rows": rows,
        ]
    }

    /// The card when no tool on this Mac has numbers: no name of a tool, no face.
    func emptySourceCard(state: AppState, lang: String) -> JSONObject {
        ["id": emptySourceId, "name": strings.t("source_none", lang),
         "note": strings.t(state.fetching ? "source_searching" : "source_none_note", lang),
         "session_pct": NSNull(), "session_face": "", "session_reset": NSNull(),
         "weekly_pct": NSNull(), "weekly_reset": NSNull(), "week_elapsed": NSNull(),
         "plan": NSNull(), "resets": NSNull(), "updated": NSNull()]
    }
}

/// Id of the empty card (not a source: never in a file name or the hidden list).
public let emptySourceId = "none"
