import Foundation
import UsageCore

/// What the Claude Code check remembers between runs (stored on AppDelegate).
struct ClaudeCodeFetchState {
    var checking = false
    var lastCheck: Date?
    /// From ~/.claude.json at the last check: who Claude Code is logged in as.
    var account: ClaudeCodeAccount?
    /// No plan account but an API key: a card without limits, nothing to fetch.
    var api = false
    /// Token in memory only; read again from the Keychain once it expires.
    var token: ClaudeCodeToken?
    /// No Keychain read before this (after a refusal or an expired token).
    var keychainNotBefore: Date?
    var lastProblem: String?
    var lastSummary: String?
    var loggedSame = false
    var loggedUnknownPlan = false
    var lastHistory: Date?
}

/// Claude Code as a source of its own (taak 43b), only when it is logged in
/// with another account than the desktop app. Every refresh interval: read the
/// token (Keychain, only when the one in memory has expired), ask the usage
/// endpoint, write usage-limits/claude-code.json. Read only, never a refresh.
extension AppDelegate {
    /// Dev build: `open "ClaudeUsage Dev.app" --args -claudeCode none` behaves as if Claude Code isn't there.
    var claudeCodeDisabled: Bool {
        isDev && UserDefaults.standard.string(forKey: "claudeCode") == "none"
    }

    /// Whether Claude Code is a source now; cheap (no file read of ~/.claude.json).
    func claudeCodeIsSource(desktopLimits: JSONObject) -> Bool {
        !claudeCodeDisabled && claudeCodeIsSeparate(claudeCode.account, desktopLimits: desktopLimits)
    }

    func maybeFetchClaudeCode() {
        let now = Date()
        guard !claudeCode.checking,
              codexCheckDue(lastCheck: claudeCode.lastCheck, now: now, interval: sourceCheckInterval(settings)) else { return }
        claudeCode.lastCheck = now
        let before = claudeCode.account, beforeAPI = claudeCode.api
        let config = claudeCodeDisabled ? [:] : loadJSONObject(claudeCodeConfigFile())
        claudeCode.account = claudeCodeAccount(claudeJSON: config)
        claudeCode.api = !claudeCodeDisabled && claudeCode.account == nil
            && claudeCodeUsesAPIKey(claudeJSON: config, keychainItemExists: claudeCodeAPIKeyItemExists())
        if claudeCode.api != beforeAPI {
            log(claudeCode.api ? "claude-code: API-key, geen planlimieten" : "claude-code: geen API-key meer")
            showCachedTitle()
            if popover.isShown { pushData() }
        }
        if claudeCode.account != before {
            claudeCode.token = nil   // another login: another token
            claudeCode.keychainNotBefore = nil
        }
        guard claudeCodeIsSource(desktopLimits: loadJSONObject(paths.limits)) else {
            if claudeCode.account != nil && !claudeCode.loggedSame {
                claudeCode.loggedSame = true
                log("claude-code: zelfde account als de desktop-app — geen aparte bron")
            }
            if before != claudeCode.account { showCachedTitle(); if popover.isShown { pushData() } }
            return
        }
        claudeCode.loggedSame = false
        if isSourceOff(claudeCodeSource) { return }   // switched off: not fetched

        let cached = claudeCode.token
        let mayRead = claudeCode.keychainNotBefore.map { now >= $0 } ?? true
        if cached?.isUsable(now: now) != true && !mayRead { return }   // waiting: no prompt storm
        claudeCode.checking = true
        let version = state.version
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var token = cached
            var keychain: String? = nil
            if token?.isUsable(now: now) != true {
                switch readClaudeCodeKeychain() {
                case .value(let v):
                    token = claudeCodeToken(keychainValue: v)
                    keychain = token == nil ? "keychain-item onleesbaar" : nil
                    DispatchQueue.main.async { self?.log("keychain: Claude Code-token opgevraagd") }
                case .missing: token = nil; keychain = "geen keychain-item"
                case .refused: token = nil; keychain = "keychain geweigerd"
                }
            }
            guard let token, token.isUsable(now: now) else {
                let problem = keychain ?? "token verlopen — gebruik Claude Code om het te verversen"
                DispatchQueue.main.async { self?.onClaudeCodeNoToken(problem, refused: keychain != nil) }
                return
            }
            URLSession.shared.dataTask(with: claudeCodeUsageRequest(token: token, appVersion: version)) { data, response, error in
                let outcome: ClaudeCodeFetchOutcome = error.map { .failed($0.localizedDescription) }
                    ?? claudeCodeOutcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                         body: data, plan: token.plan, now: Date())
                DispatchQueue.main.async { self?.onClaudeCodeResult(outcome, token: token) }
            }.resume()
        }
    }

    func onClaudeCodeNoToken(_ problem: String, refused: Bool) {
        claudeCode.checking = false
        claudeCode.token = nil
        claudeCode.keychainNotBefore = Date() + (refused ? claudeCodeRefusedRetry : claudeCodeExpiredRetry)
        claudeCodeProblem(problem)
    }

    func onClaudeCodeResult(_ outcome: ClaudeCodeFetchOutcome, token: ClaudeCodeToken) {
        claudeCode.checking = false
        claudeCode.token = token
        if let p = token.unknownPlan, !claudeCode.loggedUnknownPlan {
            claudeCode.loggedUnknownPlan = true
            log("claude-code: onbekend abonnement: \(p)")
        }
        switch outcome {
        case .limits(let limits):
            do {
                try saveJSONObject(limits, to: paths.snapshotFile(claudeCodeSource))
            } catch {
                return claudeCodeProblem("opslaan mislukt: \(error)")
            }
            if claudeCode.lastProblem != nil { log("claude-code: weer bereikbaar") }
            claudeCode.lastProblem = nil
            guard let snapshot = claudeCodeSnapshot(limits: limits, now: Date()) else { return }
            notifySource(snapshot)
            recordSourceHistory(snapshot, lastRecorded: &claudeCode.lastHistory)
            showCachedTitle()
            if popover.isShown { pushData() }
            let summary = snapshot.windows.filter { $0.kind != .other }
                .map { "\($0.kind.rawValue) \(Int($0.utilization))%" }.joined(separator: " · ")
            if summary != claudeCode.lastSummary {
                claudeCode.lastSummary = summary
                log("claude-code: \(summary)")
            }
        case .unauthorized:
            // Claude Code refreshed (or logged out): the next check reads the Keychain again.
            claudeCode.token = nil
            claudeCodeProblem("token geweigerd (401/403)")
        case .rateLimited:
            claudeCodeProblem("te veel verzoeken (429) — volgende poging bij de volgende ronde")
        case .failed(let why):
            claudeCodeProblem(why)
        }
    }

    func claudeCodeProblem(_ problem: String) {
        if problem != claudeCode.lastProblem { log("claude-code: \(problem)") }
        claudeCode.lastProblem = problem
    }
}
