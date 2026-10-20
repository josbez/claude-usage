import Foundation

// Several sources in the popover and the menu bar (taak 55f, design 55e "C1b"):
// one card per source, stacked; the menu bar shows the source closest to a limit.

/// Settings key: ids of the sources the user switched off in the popover.
public let hiddenSourcesKey = "hidden_sources"

public func hiddenSources(_ settings: JSONObject) -> Set<String> {
    Set((settings[hiddenSourcesKey] as? [Any] ?? []).compactMap { $0 as? String })
}

/// Utilization as it stands now: a window whose reset has passed is at 0
/// (the reset happened; the next numbers come with the next fetch).
public func currentUtilization(_ w: UsageWindow, now: Date) -> Double {
    if let r = w.resetsAt, r <= now { return 0 }
    return w.utilization
}

/// Sources with numbers to show: Claude when its limits file has a session or
/// week window; another source when its snapshot is younger than a week
/// (older means the tool isn't in use). A hidden source isn't fetched (taak 43b),
/// so its age says nothing: it stays, so it can be switched back on.
/// Sources without limits (API key) come last, below every card with numbers (taak 66).
public func availableSources(claude: SourceSnapshot?, others: [SourceSnapshot], now: Date,
                             hidden: Set<String> = []) -> [SourceSnapshot] {
    var out: [SourceSnapshot] = []
    if let c = claude, hasLimits(c) { out.append(c) }
    for s in others.filter(hasLimits) + others.filter({ !hasLimits($0) && isPayPerUse($0) }) {
        guard hidden.contains(s.source.id)
              || s.fetchedAt.map({ now.timeIntervalSince($0) < codexSessionMaxAge }) == true else { continue }
        out.append(s)
    }
    return out
}

/// A session or week window: numbers for the card and the menu bar.
public func hasLimits(_ s: SourceSnapshot) -> Bool { s.window(.session) != nil || s.window(.weekly) != nil }

/// Paid per use (Claude Code on an API key): a card that says so, no numbers,
/// never in the menu bar.
public func isPayPerUse(_ s: SourceSnapshot) -> Bool { s.extras["billing"] as? String == "api" }

/// The hidden set after the user flips one switch (taak 61). Hiding the last
/// visible available source is refused: the set comes back unchanged.
public func settingSourceHidden(_ hidden: Set<String>, id: String, hide: Bool,
                                available: [String]) -> Set<String> {
    var out = hidden
    if hide { out.insert(id) } else { out.remove(id) }
    if hide && available.contains(id) && !available.contains(where: { !out.contains($0) }) { return hidden }
    return out
}

/// Available minus hidden. Never empty while something is available: hiding
/// every source would leave nothing to show, so the first one stays.
public func visibleSources(_ available: [SourceSnapshot], hidden: Set<String>) -> [SourceSnapshot] {
    let visible = available.filter { !hidden.contains($0.source.id) }
    return visible.isEmpty ? Array(available.prefix(1)) : visible
}

/// How close a source is to a limit, for the glance in the menu bar: the
/// session, since that decides whether you can keep working right now and
/// shows which tool is in use. A week only counts once it is critical (the
/// weekly notification threshold); below that it moves too slowly to earn
/// the menu bar.
public func pressure(_ s: SourceSnapshot, now: Date) -> Double {
    let session = s.window(.session).map { currentUtilization($0, now: now) } ?? 0
    let weekly = s.window(.weekly).map { currentUtilization($0, now: now) } ?? 0
    return weekly >= Double(weeklyThresholds.min() ?? 90) ? max(session, weekly) : session
}

/// The source the menu bar shows: the one under the most pressure; on a tie
/// the first (Claude comes first).
public func tightestSource(_ sources: [SourceSnapshot], now: Date) -> SourceSnapshot? {
    var best: SourceSnapshot? = nil
    for s in sources where best == nil || pressure(s, now: now) > pressure(best!, now: now) { best = s }
    return best
}

/// Elapsed share of a weekly window (0–100, one decimal), from its reset time
/// and its length (a weekly window is 7 days by definition of its kind).
public func weekElapsedPct(_ w: UsageWindow, now: Date) -> Double? {
    guard w.kind == .weekly, let end = w.resetsAt, end > now else { return nil }
    let start = end - week
    return pyRound1(min(max(now.timeIntervalSince(start), 0), week) / week * 100)
}

extension UsageFormatter {
    /// "Claude", "ChatGPT": the name users know the source by (55e).
    public func sourceName(_ s: SourceSnapshot, _ lang: String) -> String {
        strings.t("source_\(s.source.tool)", lang)
    }

    /// The plan as shown: Claude's label comes from the API as text; other
    /// sources' plan ids only when a translation exists (never guessed).
    func planLabel(_ s: SourceSnapshot, _ lang: String) -> String? {
        guard let plan = s.plan, !plan.isEmpty else { return nil }
        if s.source.tool == "claude" { return plan }
        // Per tool first ("plan_claude-code_pro"): one tool's plan id says nothing about another's
        for key in ["plan_\(s.source.tool)_\(plan)", "plan_\(plan)"] {
            let text = strings.t(key, lang)
            if text != key { return text }
        }
        return nil
    }

    /// The menu bar title for one source: the same for every source, no name
    /// (taak 43b: the ring and numbers are enough; the popover says whose they are).
    public func sourceTitle(_ s: SourceSnapshot, style: String, lang: String, theme: FaceTheme?) -> String {
        let session = s.window(.session), weekly = s.window(.weekly)
        return statusTitle(session: pyInt(session.map { currentUtilization($0, now: now) } ?? 0),
                           weekly: pyInt(weekly.map { currentUtilization($0, now: now) } ?? 0),
                           compact: resetCompact(session?.resetsAt.map(isoString) ?? "", lang),
                           style: style, theme: theme)
    }

    /// Session percentage the menu bar ring shows for a source.
    public func sourceSessionPct(_ s: SourceSnapshot) -> Int {
        pyInt(s.window(.session).map { currentUtilization($0, now: now) } ?? 0)
    }

    /// One card in the popover. Missing windows stay null (the card shows "—"),
    /// never 0. `claudeLimits` adds Claude's own extras (week window start,
    /// resets on claude.ai).
    public func sourceCard(_ s: SourceSnapshot, settings: JSONObject, lang: String,
                           claudeLimits: JSONObject? = nil) -> JSONObject {
        let session = s.window(.session), weekly = s.window(.weekly)
        let sessionPct = session.map { pyInt(currentUtilization($0, now: now)) }
        let weeklyPct = weekly.map { pyInt(currentUtilization($0, now: now)) }
        func reset(_ w: UsageWindow?) -> Any {
            guard let r = w?.resetsAt, r > now else { return NSNull() }
            return resetTime(isoString(r), lang)
        }

        var card: JSONObject = [
            "id": s.source.id,
            "name": sourceName(s, lang),
            "session_pct": sessionPct ?? NSNull(),
            "session_face": faceIcon(sessionPct ?? 0, theme: faceTheme(settings)),
            "session_reset": reset(session),
            "weekly_pct": weeklyPct ?? NSNull(),
            "weekly_reset": reset(weekly),
            "plan": planLabel(s, lang) ?? NSNull(),
        ]

        var elapsed: Double? = nil
        if let limits = claudeLimits, let wp = weekProgress(limits, now: now) {
            elapsed = jsonNumber(wp["elapsed_pct"])
        } else if let w = weekly {
            elapsed = weekElapsedPct(w, now: now)
        }
        card["week_elapsed"] = elapsed ?? NSNull()

        // Free resets: Claude's open claude.ai; others are only shown.
        if let limits = claudeLimits, let view = limitResetsView(limits, lang),
           let info = limitResets(limits, now: now) {
            card["resets"] = ["text": shortResets(info.count, lang), "tip": "\(view["text"] ?? "") — \(view["tip"] ?? "")",
                              "link": true]
        } else if let c = s.resetCredits, c.available > 0 {
            var tip = c.available == 1 ? strings.t("resets_one", lang) : strings.t("resets_many", lang, ["n": c.available])
            if let e = c.nextExpiry {
                let date = shortDate(isoString(e), lang)
                if !date.isEmpty { tip += strings.t("resets_until", lang, ["date": date]) }
            }
            if !c.labels.isEmpty { tip += " — " + c.labels.joined(separator: " · ") }
            card["resets"] = ["text": shortResets(c.available, lang), "tip": tip, "link": false]
        } else {
            card["resets"] = NSNull()
        }

        if isPayPerUse(s) { card["note"] = strings.t("card_no_limits", lang) }

        // Old numbers say so on the card (a session file can be hours old).
        if !isPayPerUse(s), let f = s.fetchedAt, now.timeIntervalSince(f) / 60 > Double(staleAfterMinutes(refresh: refreshMinutes(settings))) {
            card["updated"] = strings.t("card_updated", lang, ["when": ageText(f, lang)])
        } else {
            card["updated"] = NSNull()
        }
        return card
    }

    func shortResets(_ n: Int, _ lang: String) -> String {
        n == 1 ? strings.t("resets_short_one", lang) : strings.t("resets_short_many", lang, ["n": n])
    }

    /// How old numbers are, the same everywhere (taak 61): "zojuist", "1 min
    /// geleden", "12 min geleden" within the hour, then the time ("14:52") or date.
    public func ageText(_ d: Date, _ lang: String) -> String {
        let minutes = pyInt(now.timeIntervalSince(d) / 60)
        if minutes < 1 { return strings.t("ago_now", lang) }
        if minutes == 1 { return strings.t("ago_one_min", lang) }
        if minutes < 60 { return strings.t("ago_min", lang, ["n": minutes]) }
        return whenText(d, lang)
    }

    /// "14:52" today, else "do 9 okt".
    func whenText(_ d: Date, _ lang: String) -> String {
        let p = LocalParts(d, timeZone: timeZone), today = LocalParts(now, timeZone: timeZone)
        if p.month == today.month && p.day == today.day && now.timeIntervalSince(d) < 86400 { return p.hhmm }
        return shortDate(isoString(d), lang)
    }

    /// A row in settings for a non-Claude source: where the numbers come from and how old they are.
    public func sourceStatus(_ s: SourceSnapshot, lang: String) -> String {
        if isPayPerUse(s) { return strings.t("source_api_key", lang) }
        let origin = s.extras["origin"] as? String
        var text = strings.t(origin == "session-file" ? "source_from_file" : "source_connected_\(s.source.tool)", lang)
        if let f = s.fetchedAt { text += " · " + ageText(f, lang) }
        return text
    }

    /// The menu bar title and ring percentage. Claude alone: exactly the old
    /// title. Several sources (or only another one): the tightest visible source.
    /// No source with numbers: "—" and an empty ring.
    public func menubarTitle(limits: JSONObject, others: [SourceSnapshot], settings: JSONObject,
                             lang: String) -> (title: String, sessionPct: Int) {
        let style = settings["menubar_style"] as? String ?? "full"
        let theme = faceTheme(settings)
        let available = availableSources(claude: claudeSnapshot(limits: limits, now: now), others: others, now: now,
                                         hidden: hiddenSources(settings))
        if !available.contains(where: hasLimits) { return (noDataTitle, 0) }
        if usesSourceTitle(available),
           let s = tightestSource(visibleSources(available, hidden: hiddenSources(settings)).filter(hasLimits), now: now) {
            return (sourceTitle(s, style: style, lang: lang, theme: theme), sourceSessionPct(s))
        }
        return (titleFromLimits(limits, style: style, lang: lang, theme: theme), sessionPct(limits))
    }
}

/// Only other sources have numbers: Claude never had any (nothing fetched),
/// so it isn't shown at all, not as a card, footer status or settings row.
public func claudeAbsent(_ available: [SourceSnapshot]) -> Bool {
    !available.isEmpty && !available.contains { $0.source.id == claudeDesktopSource }
}

/// Claude on its own keeps the title it always had.
func usesSourceTitle(_ available: [SourceSnapshot]) -> Bool {
    available.count > 1 || (available.first.map { $0.source.id != claudeDesktopSource } ?? false)
}
