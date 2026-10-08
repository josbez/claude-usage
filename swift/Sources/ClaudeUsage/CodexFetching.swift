import AppKit
import UsageCore

/// What the Codex check remembers between runs (stored on AppDelegate).
struct CodexFetchState {
    var checking = false
    var lastCheck: Date?
    var missingLogged = false
    /// Log only changes: the last summary, problem and unknown values seen.
    var lastSummary: String?
    var lastProblem: String?
    var loggedUnknown: Set<String> = []
    /// Session-file fallback: the file and mtime already read (taak 55i).
    var lastSessionFile: (url: URL, mtime: Date)?
    /// Last snapshot written to usage-history/codex/ (taak 55g).
    var lastHistory: Date?
}

/// Codex as a second source (taak 55c): ask `codex app-server` at most every
/// 5 minutes (after a Claude fetch, or when the popover opens) and write
/// usage-limits/codex.json. The call fails: fall back to the last event in
/// Codex's own session files (taak 55i). Not installed or not logged in
/// (codexInstalled): nothing at all, and no card (55f).
extension AppDelegate {
    func maybeFetchCodex() {
        guard !codex.checking, codexCheckDue(lastCheck: codex.lastCheck, now: Date()) else { return }
        codex.checking = true
        codex.lastCheck = Date()
        guard codexAvailable, let binary = findCodexBinary() else {
            codex.checking = false
            if !codex.missingLogged {
                codex.missingLogged = true
                log("codex: niet geïnstalleerd of niet ingelogd — geen bron")
            }
            return
        }
        codex.missingLogged = false
        let version = state.version
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = readCodexRateLimits(binary: binary, clientVersion: version)
            DispatchQueue.main.async { self?.onCodexResult(result) }
        }
    }

    /// Installed and logged in. Dev build: `open "ClaudeUsage Dev.app" --args -codexBinary none`
    /// behaves as if Codex isn't there.
    var codexAvailable: Bool {
        !(isDev && UserDefaults.standard.string(forKey: "codexBinary") == "none") && codexInstalled()
    }

    func onCodexResult(_ result: Result<JSONObject, CodexAppServerError>) {
        switch result {
        case .success(let response):
            codex.checking = false
            let parse = codexSnapshot(rateLimits: response, fetchedAt: Date(), now: Date())
            logCodexUnknown(parse.unknown)
            guard let snapshot = parse.snapshot else {
                codexProblem("geen limieten in het antwoord")
                return codexFallback()
            }
            saveCodex(snapshot, origin: "app-server")
        case .failure(let error):
            codexProblem("\(error)")
            codexFallback()
        }
    }

    /// The last rate-limits event Codex wrote itself (taak 55i).
    func codexFallback() {
        codex.checking = true
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let known = codex.lastSessionFile
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date()
            var found: (url: URL, mtime: Date)? = nil
            var parse: CodexParse? = nil
            if let file = latestCodexSessionFile(root: root, now: now),
               let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date {
                found = (file, mtime)
                // Same file, unchanged since the last read: nothing new to parse.
                if !(known?.url == file && known?.mtime == mtime) {
                    parse = lastCodexRateLimitsEvent(in: file).map { codexSessionSnapshot(event: $0, now: now) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.codex.checking = false
                self.codex.lastSessionFile = found
                guard let parse else { return }
                self.logCodexUnknown(parse.unknown)
                guard let fresh = parse.snapshot else { return }
                // Never replace newer numbers (say, from the app-server a minute ago) with an older event.
                let file = self.paths.snapshotFile(codexSource)
                if let stored = snapshot(fromJSON: loadJSONObject(file), sourceId: codexSource)?.fetchedAt,
                   let new = fresh.fetchedAt, stored >= new { return }
                self.saveCodex(fresh, origin: "session-file")
            }
        }
    }

    func saveCodex(_ snapshot: SourceSnapshot, origin: String) {
        do {
            try saveJSONObject(snapshotJSON(snapshot, origin: origin), to: paths.snapshotFile(codexSource))
        } catch {
            return codexProblem("opslaan mislukt: \(error)")
        }
        if origin == "app-server" {
            if codex.lastProblem != nil { log("codex: weer bereikbaar") }
            codex.lastProblem = nil
        }
        // Notifications and history per source (55g); an old fallback event alerts nothing.
        notifySource(snapshot)
        recordSourceHistory(snapshot, lastRecorded: &codex.lastHistory)
        // New numbers: menu bar (held while the popover is open) and popover
        showCachedTitle()
        if popover.isShown { pushData() }
        let summary = codexSummary(snapshot) + (origin == "app-server" ? "" : " (sessiebestand)")
        if summary != codex.lastSummary {
            codex.lastSummary = summary
            log("codex: \(summary)")
        }
    }

    func logCodexUnknown(_ unknown: [String]) {
        for u in unknown where !codex.loggedUnknown.contains(u) {
            codex.loggedUnknown.insert(u)
            log("codex: onbekend: \(u)")
        }
    }

    func codexProblem(_ problem: String) {
        if problem != codex.lastProblem { log("codex: \(problem)") }
        codex.lastProblem = problem
    }

    /// For the log: percentages and reset count only, never account data.
    func codexSummary(_ s: SourceSnapshot) -> String {
        let windows = s.windows.map { "\($0.kind.rawValue) \(Int($0.utilization))%" }.joined(separator: " · ")
        return windows + " · resets \(s.resetCredits?.available ?? 0)"
    }
}
