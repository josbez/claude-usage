import AppKit
import UsageCore

/// How a fetch reaches claude.ai (taak 48). Native first: plain URLSession
/// requests with the sessionKey cookie, no WebKit process at all. If
/// Cloudflare ever challenges those, the hidden webview takes over: first on
/// a light page, then on the full claude.ai app.
enum FetchMode {
    case native, webLight, webFull

    var next: FetchMode? {
        switch self {
        case .native: return .webLight
        case .webLight: return .webFull
        case .webFull: return nil
        }
    }

    var label: String {
        switch self {
        case .native: return "direct verzoek"
        case .webLight: return "webview \(AppDelegate.lightFetchPath)"
        case .webFull: return "webview claude.ai/"
        }
    }
}

/// What a single request returned. `blocked` = not an answer from the API
/// (Cloudflare challenge or an HTML page): only then is another mode worth a try.
enum NativeResponse {
    case json(status: Int, body: Any)
    case blocked(String)
    case failed(String)
}

extension AppDelegate {
    func nativeRequest(_ path: String, key: String, done: @escaping (NativeResponse) -> Void) {
        var req = URLRequest(url: URL(string: "https://claude.ai" + path)!, timeoutInterval: 20)
        req.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false   // only the desktop app's cookie, nothing stored
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: NativeResponse
            if let error {
                result = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse,
                      let cf = http.value(forHTTPHeaderField: "cf-mitigated") {
                result = .blocked("cf-mitigated=\(cf)")
            } else if let data, let body = try? JSONSerialization.jsonObject(with: data) {
                result = .json(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
            } else {
                result = .blocked("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), geen JSON")
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    /// The same requests as fetch.js: bootstrap, then each org's usage in turn.
    func nativeFetch(key: String, generation: Int) {
        let current = { [weak self] in self?.fetchGeneration == generation && self?.state.fetching == true }
        nativeRequest("/api/bootstrap", key: key) { [weak self] response in
            guard let self, current() else { return }
            switch response {
            case .blocked(let why):
                self.onFetchParsed(["ok": false, "error": "bootstrap: \(why)"], mayRetry: true)
            case .failed(let why):
                self.onFetchParsed(["ok": false, "error": why], mayRetry: false)
            case .json(let status, _) where status != 200:
                self.onFetchParsed(["ok": false, "error": "bootstrap: HTTP \(status)"], mayRetry: false)
            case .json(_, let bootstrap):
                let orgs = fetchOrgs(bootstrap: bootstrap)
                var usage: [String: JSONObject] = [:]
                var blocked = false
                func step(_ i: Int) {
                    guard current() else { return }
                    guard i < orgs.count else {
                        let result = nativeFetchResult(bootstrap: bootstrap, orgs: orgs, usage: usage)
                        // Only worth another mode if Cloudflare got in the way of the usage calls.
                        self.onFetchParsed(result, mayRetry: blocked)
                        return
                    }
                    self.nativeRequest("/api/organizations/\(orgs[i].id)/usage?cedar_ember=1", key: key) { r in
                        switch r {
                        case .json(200, let body as JSONObject) where isUsageResponse(body):
                            usage[orgs[i].id] = body
                        case .blocked:
                            blocked = true
                        default:
                            break   // like fetch.js: an org without usage data is skipped
                        }
                        step(i + 1)
                    }
                }
                step(0)
            }
        }
    }
}
