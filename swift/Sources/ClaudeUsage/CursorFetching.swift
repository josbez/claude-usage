import Foundation
import UsageCore

/// What the Cursor check remembers between runs (stored on AppDelegate).
struct CursorFetchState {
    var checking = false
    var lastCheck: Date?
    /// Token in memory only; read again from Cursor's database once it expires or is rejected.
    var auth: CursorAuth?
    /// After a 429: no request before this, whatever the refresh setting.
    var notBefore: Date?
    var lastProblem: String?
    var lastSummary: String?
    var loggedUnknownPlan = false
}

/// Cursor as a source (taak 41), only while Cursor is installed and logged in.
/// Every refresh interval: read the token from Cursor's state database (only
/// when the one in memory has expired), ask the usage endpoint, write
/// usage-limits/cursor.json. Read only, never a refresh.
extension AppDelegate {
    /// Dev build: `open "ClaudeUsage Dev.app" --args -cursor none` behaves as if Cursor isn't there.
    var cursorDisabled: Bool {
        isDev && UserDefaults.standard.string(forKey: "cursor") == "none"
    }

    /// Cursor's state database exists (installed and used once); cheap.
    var cursorInstalled: Bool {
        !cursorDisabled && FileManager.default.fileExists(atPath: cursorStateDB().path)
    }

    func maybeFetchCursor() {
        let now = Date()
        guard cursorInstalled, !cursor.checking, cursor.notBefore.map({ now >= $0 }) ?? true,
              codexCheckDue(lastCheck: cursor.lastCheck, now: now, interval: sourceCheckInterval(settings)) else { return }
        cursor.lastCheck = now
        if isSourceOff(cursorSource) { return }   // switched off: not fetched
        cursor.checking = true
        let cached = cursor.auth
        let version = state.version
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var auth = cached
            if auth?.isUsable(now: now) != true {
                auth = cursorAuth(values: readCursorAuthValues(db: cursorStateDB()))
            }
            guard let auth, auth.isUsable(now: now) else {
                let problem = auth == nil ? "not logged in" : "token expired — open Cursor to refresh it"
                DispatchQueue.main.async { self?.onCursorNoAuth(problem) }
                return
            }
            URLSession.shared.dataTask(with: cursorUsageRequest(auth: auth, appVersion: version)) { data, response, error in
                let outcome: CursorFetchOutcome = error.map { .failed($0.localizedDescription) }
                    ?? cursorOutcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                     body: data, plan: auth.plan, now: Date())
                let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                DispatchQueue.main.async { self?.onCursorResult(outcome, auth: auth, retryAfter: retryAfter) }
            }.resume()
        }
    }

    func onCursorNoAuth(_ problem: String) {
        cursor.checking = false
        cursor.auth = nil
        cursorProblem(problem)
    }

    func onCursorResult(_ outcome: CursorFetchOutcome, auth: CursorAuth, retryAfter: String?) {
        cursor.checking = false
        cursor.auth = auth
        if let p = auth.unknownPlan, !cursor.loggedUnknownPlan {
            cursor.loggedUnknownPlan = true
            log("cursor: unknown plan: \(p)")
        }
        switch outcome {
        case .snapshot(let snapshot):
            do {
                try saveJSONObject(snapshotJSON(snapshot, origin: "api"), to: paths.snapshotFile(cursorSource))
            } catch {
                return cursorProblem("saving failed: \(error)")
            }
            if cursor.lastProblem != nil { log("cursor: reachable again") }
            cursor.lastProblem = nil
            showCachedTitle()
            if popover.isShown { pushData() }
            let summary = snapshot.windows.map { "\($0.kind.rawValue) \(Int($0.utilization))%" }.joined(separator: " · ")
            if summary != cursor.lastSummary {
                cursor.lastSummary = summary
                log("cursor: \(summary)")
            }
        case .unauthorized:
            // Cursor refreshed (or logged out): the next check reads its database again.
            cursor.auth = nil
            cursorProblem("token rejected (401/403)")
        case .rateLimited:
            let wait = claudeCodeBackoff(retryAfter: retryAfter)
            cursor.notBefore = Date() + wait
            cursorProblem("too many requests (429), waiting \(Int(wait / 60)) min")
        case .failed(let why):
            cursorProblem(why)
        }
    }

    func cursorProblem(_ problem: String) {
        if problem != cursor.lastProblem { log("cursor: \(problem)") }
        cursor.lastProblem = problem
    }
}
