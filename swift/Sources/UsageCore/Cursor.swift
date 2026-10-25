import Foundation
import SQLite3

// Cursor as a usage source (taak 41). Probe 25-10-2026: the access token Cursor
// keeps in its state database gets 200 from the endpoint Cursor's own usage
// view uses: the billing cycle (a month) and the share of the plan used.
// No official API: the endpoint can change without notice (accepted by Jos,
// 25-10-2026). Read only: the token is never refreshed, stored or logged.

public let cursorSource = "cursor"

public let cursorUsageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

/// Plans seen in real data. Anything else: no plan label (logged), never guessed.
let cursorKnownPlans: Set<String> = ["free"]

public func cursorStateDB(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
}

/// The login from Cursor's state database. `description` never shows the token.
public struct CursorAuth: CustomStringConvertible {
    public let accessToken: String
    public let expiresAt: Date?
    /// stripeMembershipType, only when known.
    public let plan: String?
    public let unknownPlan: String?

    /// Usable for at least another minute. No expiry in the token: assume usable (a 401 says otherwise).
    public func isUsable(now: Date) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) > 60 } ?? true
    }

    public var description: String { "CursorAuth(redacted)" }
}

/// The `exp` claim of a JWT, without checking anything else.
func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    guard let data = Data(base64Encoded: b64),
          let claims = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
          let exp = jsonNumber(claims["exp"]) else { return nil }
    return Date(timeIntervalSince1970: exp)
}

/// The login from the `cursorAuth/*` values; nil when Cursor isn't logged in.
public func cursorAuth(values: [String: String]) -> CursorAuth? {
    guard let token = values["cursorAuth/accessToken"], !token.isEmpty else { return nil }
    let raw = (values["cursorAuth/stripeMembershipType"] ?? "").lowercased()
    let known = cursorKnownPlans.contains(raw)
    return CursorAuth(accessToken: token, expiresAt: jwtExpiry(token),
                      plan: known ? raw : nil, unknownPlan: raw.isEmpty || known ? nil : raw)
}

/// The two `cursorAuth/*` values from the state database; [:] when it can't be
/// read. Works on a copy (with its write-ahead log): Cursor keeps the live DB open.
public func readCursorAuthValues(db: URL) -> [String: String] {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("claudeusage-\(UUID().uuidString)")
    guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return [:] }
    defer { try? fm.removeItem(at: dir) }
    let copy = dir.appendingPathComponent("state.vscdb")
    guard (try? fm.copyItem(at: db, to: copy)) != nil else { return [:] }
    let wal = URL(fileURLWithPath: db.path + "-wal")
    if fm.fileExists(atPath: wal.path) { try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }

    var handle: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        sqlite3_close(handle)
        return [:]
    }
    defer { sqlite3_close(handle) }
    var stmt: OpaquePointer?
    let sql = "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/stripeMembershipType')"
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_finalize(stmt) }
    var out: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let k = sqlite3_column_text(stmt, 0) else { continue }
        // value is TEXT or BLOB depending on the writer
        let n = Int(sqlite3_column_bytes(stmt, 1))
        let v = sqlite3_column_blob(stmt, 1).map { String(decoding: Data(bytes: $0, count: n), as: UTF8.self) } ?? ""
        out[String(cString: k)] = v
    }
    return out
}

public func cursorUsageRequest(auth: CursorAuth, appVersion: String) -> URLRequest {
    var req = URLRequest(url: cursorUsageURL, timeoutInterval: 20)
    req.httpMethod = "POST"
    req.httpBody = Data("{}".utf8)
    req.setValue("Bearer " + auth.accessToken, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    req.setValue("UsageMeter/\(appVersion)", forHTTPHeaderField: "User-Agent")
    return req
}

public enum CursorFetchOutcome: Equatable {
    case snapshot(SourceSnapshot)
    /// 401/403: the token is no longer valid (Cursor refreshed or logged out).
    case unauthorized
    case rateLimited
    case failed(String)

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.unauthorized, .unauthorized), (.rateLimited, .rateLimited): return true
        case let (.failed(x), .failed(y)): return x == y
        case let (.snapshot(x), .snapshot(y)): return x.windows == y.windows && x.plan == y.plan && x.fetchedAt == y.fetchedAt
        default: return false
        }
    }
}

/// The HTTP answer as an outcome: one monthly window, the share of the plan
/// used in the current billing cycle. No percentage in the body: failed, not 0%.
public func cursorOutcome(status: Int, body: Data?, plan: String?, now: Date) -> CursorFetchOutcome {
    switch status {
    case 200: break
    case 401, 403: return .unauthorized
    case 429: return .rateLimited
    default: return .failed("HTTP \(status)")
    }
    guard let body, let obj = (try? JSONSerialization.jsonObject(with: body)) as? JSONObject else {
        return .failed("response unreadable")
    }
    guard let usage = obj["planUsage"] as? JSONObject, let pct = jsonNumber(usage["totalPercentUsed"]) else {
        return .failed("no plan usage in the response")
    }
    // Milliseconds since 1970, as a string (protobuf int64) or a number
    let endMs = jsonNumber(obj["billingCycleEnd"]) ?? (obj["billingCycleEnd"] as? String).flatMap(Double.init)
    let window = UsageWindow(id: "billing_cycle", kind: .monthly, utilization: min(max(pct, 0), 100),
                             resetsAt: endMs.map { Date(timeIntervalSince1970: $0 / 1000) })
    return .snapshot(SourceSnapshot(source: UsageSource(id: cursorSource, tool: "cursor", accountLabel: ""),
                                    windows: [window], fetchedAt: now, plan: plan, resetCredits: nil,
                                    extras: ["origin": "api"]))
}
