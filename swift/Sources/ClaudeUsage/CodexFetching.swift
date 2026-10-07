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
}

/// Codex as a second source (taak 55c): ask `codex app-server` at most every
/// 5 minutes (after a Claude fetch, or when the popover opens) and write
/// usage-limits/codex.json. Nothing shows it yet (55f).
extension AppDelegate {
    func maybeFetchCodex() {
        guard !codex.checking, codexCheckDue(lastCheck: codex.lastCheck, now: Date()) else { return }
        guard let binary = findCodexBinary() else {
            if !codex.missingLogged {
                codex.missingLogged = true
                log("codex: geen codex-programma gevonden — bron overgeslagen")
            }
            return
        }
        codex.checking = true
        codex.lastCheck = Date()
        let version = state.version
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = readCodexRateLimits(binary: binary, clientVersion: version)
            DispatchQueue.main.async { self?.onCodexResult(result) }
        }
    }

    func onCodexResult(_ result: Result<JSONObject, CodexAppServerError>) {
        codex.checking = false
        let response: JSONObject
        switch result {
        case .success(let r): response = r
        case .failure(let error): return codexProblem("\(error)")
        }
        let parse = codexSnapshot(rateLimits: response, fetchedAt: Date(), now: Date())
        for u in parse.unknown where !codex.loggedUnknown.contains(u) {
            codex.loggedUnknown.insert(u)
            log("codex: onbekend: \(u)")
        }
        guard let snapshot = parse.snapshot else { return codexProblem("geen limieten in het antwoord") }
        do {
            try saveJSONObject(snapshotJSON(snapshot), to: paths.snapshotFile(codexSource))
        } catch {
            return codexProblem("opslaan mislukt: \(error)")
        }
        if codex.lastProblem != nil { log("codex: weer bereikbaar") }
        codex.lastProblem = nil
        let summary = codexSummary(snapshot)
        if summary != codex.lastSummary {
            codex.lastSummary = summary
            log("codex: \(summary)")
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
