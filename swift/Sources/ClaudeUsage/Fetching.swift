import AppKit
import CommonCrypto
import UsageCore
import WebKit

/// Usage fetch through a hidden WKWebView that carries the desktop app's
/// sessionKey cookie (gets past Cloudflare), plus the Claude status check.
/// Port of the fetch part of app.py.
extension AppDelegate {
    static let fetchTimeout: TimeInterval = 45

    func sessionKey() -> String? {
        do {
            return try claudeSessionKey()
        } catch {
            log("cookie decrypt: \(error)")
            return nil
        }
    }

    func sessionCookie(_ value: String) -> HTTPCookie? {
        HTTPCookie(properties: [.domain: ".claude.ai", .name: "sessionKey", .path: "/",
                                .value: value, .secure: "TRUE"])
    }

    static func sha256Hex(_ s: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(s.utf8)
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var cookieDBMtime: Date? {
        guard let db = findCookieDB() else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: db.path))?[.modificationDate] as? Date
    }

    func setupFetchWebView() {
        guard let key = sessionKey() else { return }
        guard !key.isEmpty else {
            log("geen sessionKey gevonden — is de Claude desktop-app ingelogd?")
            state.loggedIn = false
            return
        }
        state.loggedIn = true
        lastSessionHash = Self.sha256Hex(key)
        lastCookieMtime = cookieDBMtime

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(ScriptHandler(owner: self), name: "fetchResult")
        if let cookie = sessionCookie(key) {
            config.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let nav = FetchNavDelegate(owner: self)
        fetchNavDelegate = nav   // WKWebView keeps its navigation delegate weak
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.navigationDelegate = nav
        fetchWebView = wv
    }

    /// The sessionKey rotates: re-read it before every fetch.
    func refreshSessionCookie() {
        guard let key = sessionKey() else { return }
        guard !key.isEmpty else { state.loggedIn = false; return }
        state.loggedIn = true
        if let wv = fetchWebView, let cookie = sessionCookie(key) {
            wv.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
    }

    /// Account switch in the desktop app = sessionKey change: refetch right away.
    /// The cookie DB's mtime is a cheap first filter, so we only decrypt when it moved.
    func checkAccountSwitch() {
        guard let mtime = cookieDBMtime else { return }
        if let last = lastCookieMtime, last == mtime { return }
        lastCookieMtime = mtime
        guard let key = sessionKey() else { return }
        guard !key.isEmpty else { state.loggedIn = false; return }
        state.loggedIn = true
        let hash = Self.sha256Hex(key)
        if let last = lastSessionHash, last != hash {
            log("account gewisseld (sessionKey gewijzigd) — direct verversen")
            lastSessionHash = hash
            startFetch()
            return
        }
        lastSessionHash = hash
    }

    func startFetch() {
        if state.fetching { return }
        if fetchWebView == nil {
            // e.g. the cookie wasn't available at startup
            setupFetchWebView()
            guard fetchWebView != nil else { pushData(); return }
        } else {
            refreshSessionCookie()
        }
        state.fetching = true
        let current = (statusItem.button?.title ?? "").replacingOccurrences(of: devMark, with: "")
        let icon = current.split(separator: " ").first.map(String.init) ?? "🚀"
        // Emoji-only style stays emoji-only while fetching; others show "…"
        setStatusTitle(settings["menubar_style"] as? String == "emoji" ? icon : "\(icon) …")
        pushStatus("fetching")

        // Without a watchdog a fetch that never calls back blocks every later refresh.
        watchdog?.invalidate()
        let t = Timer(timeInterval: Self.fetchTimeout, repeats: false) { [weak self] _ in
            self?.fetchWatchdogFired()
        }
        RunLoop.current.add(t, forMode: .common)
        watchdog = t
        fetchWebView?.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    func fetchWatchdogFired() {
        watchdog = nil
        guard state.fetching else { return }
        log("fetch watchdog: geen resultaat binnen \(Int(Self.fetchTimeout))s, reset")
        state.lastFetchError = "time-out"
        state.fetching = false
        pushStatus("ready")
        showCachedTitle()
    }

    func cancelWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    func onFetchPageLoaded() {
        let t = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, let wv = self.fetchWebView else { return }
            wv.evaluateJavaScript(buildFetchJS(template: self.fetchJSTemplate,
                deliver: "window.webkit.messageHandlers.fetchResult.postMessage(s);"))
        }
        RunLoop.current.add(t, forMode: .common)
    }

    func onFetchFailed() {
        cancelWatchdog()
        state.fetching = false
        log("fetch: pagina laden mislukt (navigatiefout)")
        state.lastFetchError = "pagina laden mislukt"
        pushStatus("ready")
        showCachedTitle()
    }

    func onFetchResult(_ raw: String) {
        cancelWatchdog()
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? JSONObject {
            if (parsed["ok"] as? Bool) == true {
                let output = limitsOutput(parsed, now: Date())
                do {
                    try saveJSONObject(output, to: paths.limits)
                    state.lastFetchError = nil
                } catch {
                    log("limieten opslaan mislukt: \(error)")
                    state.lastFetchError = "opslaan mislukt"
                }
                recordHistory(output)
                logBlockReasons(parsed, output)
                logCedarEmber(output)
                notifyLimits(output)
            } else {
                let error = parsed["error"] as? String ?? "onbekende fout"
                log("fetch mislukt: \(error)")
                state.lastFetchError = error
            }
        } else {
            log("fetch resultaat onleesbaar")
            state.lastFetchError = "resultaat onleesbaar"
        }
        state.fetching = false
        showCachedTitle()
        pushData()
    }

    func pushStatus(_ status: String) {
        webView.evaluateJavaScript("if(window.setStatus) window.setStatus('\(status)')")
    }

    // MARK: - Logging what the API tells us (never breaks a fetch)

    func logBlockReasons(_ parsed: JSONObject, _ limits: JSONObject) {
        let account = limits["account_email"] as? String ?? ""
        guard !account.isEmpty else { return }
        let (entries, seen) = newBlockLogEntries(limits: limits, bootstrapFields: parsed["bootstrap_fields"],
                                                 account: account, seen: loadJSONObject(paths.blockLogState))
        entries.forEach(log)
        if !entries.isEmpty { try? saveJSONObject(seen, to: paths.blockLogState) }
    }

    /// Log the real cedar_ember shape once per change, and any shape we don't know.
    func logCedarEmber(_ limits: JSONObject) {
        let account = limits["account_email"] as? String ?? ""
        var state = loadJSONObject(paths.blockLogState)
        let key: String, line: String, digestSource: Any
        if cedarEmberUnrecognised(limits) {
            key = "\(account)|cedar_ember_shape"
            digestSource = limits["cedar_ember"]!
            line = "cedar_ember: onbekende vorm: \(String(pyStr(limits["cedar_ember"]).prefix(300)))"
        } else if let stable = cedarEmberStable(limits) {
            key = "\(account)|cedar_ember"
            digestSource = stable
            line = "cedar_ember: \(jsonText(stable))"
        } else {
            return
        }
        let digest = Self.sha256Hex(jsonText(digestSource))
        if state[key] as? String != digest {
            state[key] = digest
            log(line)
            try? saveJSONObject(state, to: paths.blockLogState)
        }
    }

    func jsonText(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject([v]),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed])
        else { return "\(v)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Claude service status (separate from the usage fetch)

    func maybeCheckServiceStatus() {
        if serviceChecking { return }
        if let last = serviceCheckedAt, Date().timeIntervalSince(last) < statusCheckInterval { return }
        serviceChecking = true
        serviceCheckedAt = Date()
        var req = URLRequest(url: statusSummaryURL, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeUsage-status", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let summary = ok ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) } : nil
            let problem = error?.localizedDescription ?? (ok ? nil : "HTTP-fout")
            DispatchQueue.main.async { self?.onServiceStatus(summary, problem) }
        }.resume()
    }

    func onServiceStatus(_ summary: Any?, _ error: String?) {
        serviceChecking = false
        if let error {
            log("claude-status ophalen mislukt: \(error)")
            state.service = ["level": "unreachable"]
        } else if let parsed = serviceStatus(summary) {
            for value in parsed["unknown"] as? [String] ?? [] where !loggedUnknownStatus.contains(value) {
                loggedUnknownStatus.insert(value)
                log("claude-status: onbekende waarde \(value)")
            }
            state.service = parsed
        } else {
            log("claude-status: onbruikbare respons")
            state.service = ["level": "unreachable"]
        }
        pushData()
    }
}

final class FetchNavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: AppDelegate?
    init(owner: AppDelegate) { self.owner = owner }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.onFetchPageLoaded()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.onFetchFailed()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        owner?.onFetchFailed()
    }
}
