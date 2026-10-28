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
    /// The organization of the token last read from the Keychain (its profile).
    /// nil: not known yet, ~/.claude.json's account counts until then.
    var tokenOrg: String?
    /// No Keychain read before this (after a refusal or an expired token).
    var keychainNotBefore: Date?
    /// After a 429: no request before this, whatever the refresh setting.
    var notBefore: Date?
    /// After an expired token: ~/.claude.json's mtime then. Claude Code writes it
    /// while in use, so a newer mtime means it may have refreshed: read again at once.
    var expiredConfigMtime: Date?
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
        let account = claudeCode.account.map { a in claudeCode.tokenOrg.map(ClaudeCodeAccount.init) ?? a }
        return !claudeCodeDisabled && claudeCodeIsSeparate(account, desktopLimits: desktopLimits)
    }

    func maybeFetchClaudeCode() {
        let now = Date()
        guard !claudeCode.checking, claudeCode.notBefore.map({ now >= $0 }) ?? true,
              codexCheckDue(lastCheck: claudeCode.lastCheck, now: now, interval: sourceCheckInterval(settings)) else { return }
        claudeCode.lastCheck = now
        let before = claudeCode.account, beforeAPI = claudeCode.api
        let config = claudeCodeDisabled ? [:] : loadJSONObject(claudeCodeConfigFile())
        claudeCode.account = claudeCodeAccount(claudeJSON: config)
        claudeCode.api = !claudeCodeDisabled && claudeCode.account == nil
            && claudeCodeUsesAPIKey(claudeJSON: config, keychainItemExists: claudeCodeAPIKeyItemExists())
        if claudeCode.api != beforeAPI {
            log(claudeCode.api ? "claude-code: API key, no plan limits" : "claude-code: no API key anymore")
            showCachedTitle()
            if popover.isShown { pushData() }
        }
        if claudeCode.account != before {
            claudeCode.token = nil   // another login: another token
            claudeCode.tokenOrg = nil
            claudeCode.keychainNotBefore = nil
        }
        // ~/.claude.json can name another account than the token in use: the same
        // account there only counts once a token's profile says so too.
        let verify = claudeCode.account != nil && !claudeCodeDisabled && claudeCode.tokenOrg == nil
        guard verify || claudeCodeIsSource(desktopLimits: loadJSONObject(paths.limits)) else {
            if claudeCode.account != nil && !claudeCode.loggedSame {
                claudeCode.loggedSame = true
                log("claude-code: same account as the desktop app — no separate source")
            }
            if before != claudeCode.account { showCachedTitle(); if popover.isShown { pushData() } }
            return
        }
        if !verify { claudeCode.loggedSame = false }
        if isSourceOff(claudeCodeSource) { return }   // switched off: not fetched

        let cached = claudeCode.token
        let configMtime = (try? FileManager.default.attributesOfItem(atPath: claudeCodeConfigFile().path))?[.modificationDate] as? Date
        let usedSince = claudeCode.expiredConfigMtime.map { old in configMtime.map { $0 > old } ?? false } ?? false
        let mayRead = usedSince || (claudeCode.keychainNotBefore.map { now >= $0 } ?? true)
        if cached?.isUsable(now: now) != true && !mayRead { return }   // waiting: no prompt storm
        claudeCode.checking = true
        let version = state.version
        let knownOrg = claudeCode.tokenOrg
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var token = cached
            var keychain: String? = nil
            var read = false
            if token?.isUsable(now: now) != true {
                switch readClaudeCodeKeychain() {
                case .value(let v):
                    token = claudeCodeToken(keychainValue: v)
                    read = true
                    keychain = token == nil ? "keychain item unreadable" : nil
                    DispatchQueue.main.async { self?.log("keychain: Claude Code token requested") }
                case .missing: token = nil; keychain = "no keychain item"
                case .refused: token = nil; keychain = "keychain denied"
                }
            }
            guard let token, token.isUsable(now: now) else {
                let problem = keychain ?? "token expired — use Claude Code to refresh it"
                DispatchQueue.main.async { self?.onClaudeCodeNoToken(problem, refused: keychain != nil) }
                return
            }
            guard read || knownOrg == nil else { self?.fetchClaudeCodeUsage(token: token, version: version); return }
            // A token from the Keychain: whose is it? Never logged, only compared.
            URLSession.shared.dataTask(with: claudeCodeProfileRequest(token: token, appVersion: version)) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let org = claudeCodeProfileOrg(status: status, body: data)
                DispatchQueue.main.async {
                    if org == nil { self?.log("claude-code: profile unknown (\(error?.localizedDescription ?? "HTTP \(status)")), using ~/.claude.json") }
                    self?.onClaudeCodeProfile(org, token: token, version: version)
                }
            }.resume()
        }
    }

    /// The token's organization known (nil: profile unreachable, ~/.claude.json
    /// counts): fetch its usage only when that is another account than the desktop app.
    func onClaudeCodeProfile(_ org: String?, token: ClaudeCodeToken, version: String) {
        let wasSource = claudeCodeIsSource(desktopLimits: loadJSONObject(paths.limits))
        claudeCode.token = token
        if let org { claudeCode.tokenOrg = org }
        let isSource = claudeCodeIsSource(desktopLimits: loadJSONObject(paths.limits))
        if isSource != wasSource { showCachedTitle(); if popover.isShown { pushData() } }
        guard isSource, !isSourceOff(claudeCodeSource) else {
            claudeCode.checking = false
            if !isSource && !claudeCode.loggedSame {
                claudeCode.loggedSame = true
                log("claude-code: same account as the desktop app — no separate source")
            }
            return
        }
        claudeCode.loggedSame = false
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.fetchClaudeCodeUsage(token: token, version: version) }
    }

    func fetchClaudeCodeUsage(token: ClaudeCodeToken, version: String) {
        URLSession.shared.dataTask(with: claudeCodeUsageRequest(token: token, appVersion: version)) { [weak self] data, response, error in
            let outcome: ClaudeCodeFetchOutcome = error.map { .failed($0.localizedDescription) }
                ?? claudeCodeOutcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                     body: data, plan: token.plan, now: Date())
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            DispatchQueue.main.async { self?.onClaudeCodeResult(outcome, token: token, retryAfter: retryAfter) }
        }.resume()
    }

    func onClaudeCodeNoToken(_ problem: String, refused: Bool) {
        claudeCode.checking = false
        claudeCode.token = nil
        claudeCode.keychainNotBefore = Date() + (refused ? claudeCodeRefusedRetry : claudeCodeExpiredRetry)
        // Expired: Claude Code's next activity may bring a fresh token. Refused: wait (no prompt storm).
        claudeCode.expiredConfigMtime = refused ? nil
            : (try? FileManager.default.attributesOfItem(atPath: claudeCodeConfigFile().path))?[.modificationDate] as? Date
        claudeCodeProblem(problem)
    }

    func onClaudeCodeResult(_ outcome: ClaudeCodeFetchOutcome, token: ClaudeCodeToken, retryAfter: String? = nil) {
        claudeCode.checking = false
        claudeCode.token = token
        claudeCode.expiredConfigMtime = nil
        if let p = token.unknownPlan, !claudeCode.loggedUnknownPlan {
            claudeCode.loggedUnknownPlan = true
            log("claude-code: unknown plan: \(p)")
        }
        switch outcome {
        case .limits(let limits):
            do {
                try saveJSONObject(limits, to: paths.snapshotFile(claudeCodeSource))
            } catch {
                return claudeCodeProblem("saving failed: \(error)")
            }
            if claudeCode.lastProblem != nil { log("claude-code: reachable again") }
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
            claudeCodeProblem("token rejected (401/403)")
        case .rateLimited:
            let wait = claudeCodeBackoff(retryAfter: retryAfter)
            claudeCode.notBefore = Date() + wait
            claudeCodeProblem("too many requests (429), waiting \(Int(wait / 60)) min")
        case .failed(let why):
            claudeCodeProblem(why)
        }
    }

    func claudeCodeProblem(_ problem: String) {
        if problem != claudeCode.lastProblem { log("claude-code: \(problem)") }
        claudeCode.lastProblem = problem
    }
}
