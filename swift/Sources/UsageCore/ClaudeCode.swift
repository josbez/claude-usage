import Foundation

// Claude Code as a usage source (taak 43b). Probe 43a (19-10-2026): the OAuth
// token Claude Code keeps in the Keychain gets 200 from api.anthropic.com's
// usage endpoint, with the same body as claude.ai's (five_hour, seven_day,
// limits, …); claude.ai itself refuses that token (403).
// Read only: the token is never refreshed (that rotates Claude Code's refresh
// token and logs it out), never stored, never logged.

public let claudeCodeSource = "claude-code"

public let claudeCodeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

/// The Keychain item of the default config dir (~/.claude). Items with a
/// `-<hex>` suffix belong to other CLAUDE_CONFIG_DIRs (desktop-app sessions, …): ignored.
public let claudeCodeKeychainService = "Claude Code-credentials"

/// Plans seen in real credentials. Anything else: no plan label (logged), never guessed.
let claudeCodeKnownPlans: Set<String> = ["pro", "max", "team", "enterprise"]

/// The account Claude Code is logged in with, from ~/.claude.json (no Keychain,
/// no prompt). nil: Claude Code isn't installed or isn't logged in.
public struct ClaudeCodeAccount: Equatable {
    public let organizationId: String
}

public func claudeCodeAccount(claudeJSON: JSONObject) -> ClaudeCodeAccount? {
    guard let a = claudeJSON["oauthAccount"] as? JSONObject,
          let org = a["organizationUuid"] as? String, !org.isEmpty else { return nil }
    return ClaudeCodeAccount(organizationId: org)
}

/// Claude Code without a plan account but with an API key (Console login: the
/// Keychain item "Claude Code"; or a key from the environment it was told to
/// accept). Pay per use: there are no plan limits to show, only that.
/// Only the existence of the item and the config entries is checked, never a key.
public func claudeCodeUsesAPIKey(claudeJSON: JSONObject, keychainItemExists: Bool) -> Bool {
    guard claudeJSON["oauthAccount"] == nil else { return false }
    let approved = ((claudeJSON["customApiKeyResponses"] as? JSONObject)?["approved"] as? [Any]) ?? []
    return keychainItemExists || !approved.isEmpty || claudeJSON["primaryApiKey"] != nil
}

/// Whether the Keychain has Claude Code's API-key item. Attributes only (no -w):
/// no prompt, nothing secret read.
public func claudeCodeAPIKeyItemExists() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// Claude Code on an API key as a source: a card without numbers that says so.
public func claudeCodeAPISnapshot(now: Date) -> SourceSnapshot {
    SourceSnapshot(source: UsageSource(id: claudeCodeSource, tool: "claude-code", accountLabel: ""),
                   windows: [], fetchedAt: now, plan: "api", resetCredits: nil,
                   extras: ["origin": "config", "billing": "api"])
}

public func claudeCodeConfigFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent(".claude.json")
}

/// Claude Code is a source of its own only when it uses another account than
/// the desktop app: the same organization would show the same numbers twice.
/// Desktop app without an account (logged out, never fetched): Claude Code counts.
public func claudeCodeIsSeparate(_ code: ClaudeCodeAccount?, desktopLimits: JSONObject) -> Bool {
    guard let code else { return false }
    let desktop = desktopLimits["org_id"] as? String ?? ""
    return desktop.isEmpty || desktop != code.organizationId
}

/// The access token from the Keychain item's JSON. `description` never shows it.
public struct ClaudeCodeToken: CustomStringConvertible {
    public let accessToken: String
    public let expiresAt: Date?
    /// subscriptionType ("pro", "max", …), only when known.
    public let plan: String?
    public let unknownPlan: String?

    /// Usable for at least another minute. No expiry in the item: assume usable
    /// (a 401 says otherwise).
    public func isUsable(now: Date) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) > 60 } ?? true
    }

    public var description: String { "ClaudeCodeToken(redacted)" }
}

public func claudeCodeToken(keychainValue: String) -> ClaudeCodeToken? {
    guard let data = keychainValue.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
          let oauth = obj["claudeAiOauth"] as? JSONObject,
          let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
    let expires = jsonNumber(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
    let raw = (oauth["subscriptionType"] as? String)?.lowercased() ?? ""
    let known = claudeCodeKnownPlans.contains(raw)
    return ClaudeCodeToken(accessToken: token, expiresAt: expires,
                           plan: known ? raw : nil, unknownPlan: raw.isEmpty || known ? nil : raw)
}

public enum ClaudeCodeKeychainResult {
    case value(String)
    /// No item: Claude Code never logged in with the default config dir.
    case missing
    /// Deny, Esc, or any other refusal.
    case refused
}

/// Via /usr/bin/security, like the cookie password (valkuil 9): the user's
/// "Always Allow" for `security` then also covers later reads.
public func readClaudeCodeKeychain() -> ClaudeCodeKeychainResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", claudeCodeKeychainService, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return .refused }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    switch p.terminationStatus {
    case 0: return .value(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    case 44: return .missing   // errSecItemNotFound
    default: return .refused
    }
}

/// How long to wait before asking the Keychain again after a read that gave
/// nothing usable: a refusal could mean a prompt each time; an expired token
/// only changes once Claude Code is used again.
public let claudeCodeRefusedRetry: TimeInterval = 60 * 60
public let claudeCodeExpiredRetry: TimeInterval = 30 * 60

public func claudeCodeUsageRequest(token: ClaudeCodeToken, appVersion: String) -> URLRequest {
    var req = URLRequest(url: claudeCodeUsageURL, timeoutInterval: 20)
    req.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("UsageMeter/\(appVersion)", forHTTPHeaderField: "User-Agent")
    return req
}

public enum ClaudeCodeFetchOutcome: Equatable {
    /// The usage body plus fetched_at and plan: the snapshot file as stored.
    case limits(JSONObject)
    /// 401/403: the token is no longer valid (Claude Code refreshed or logged out).
    case unauthorized
    case rateLimited
    case failed(String)

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.unauthorized, .unauthorized), (.rateLimited, .rateLimited): return true
        case let (.failed(x), .failed(y)): return x == y
        case let (.limits(x), .limits(y)): return NSDictionary(dictionary: x).isEqual(to: y)
        default: return false
        }
    }
}

/// The HTTP answer as an outcome. A body without a session or week window
/// isn't usage data: failed, not 0%.
public func claudeCodeOutcome(status: Int, body: Data?, plan: String?, now: Date) -> ClaudeCodeFetchOutcome {
    switch status {
    case 200: break
    case 401, 403: return .unauthorized
    case 429: return .rateLimited
    default: return .failed("HTTP \(status)")
    }
    guard let body, var obj = (try? JSONSerialization.jsonObject(with: body)) as? JSONObject else {
        return .failed("antwoord onleesbaar")
    }
    guard obj["five_hour"] is JSONObject || obj["seven_day"] is JSONObject else {
        return .failed("geen limieten in het antwoord")
    }
    obj["source"] = claudeCodeSource
    obj["origin"] = "oauth"
    obj["fetched_at"] = isoString(now)
    obj["plan"] = plan ?? NSNull()
    return .limits(obj)
}

/// The stored file as a snapshot: the same body as Claude's, so the same windows,
/// resets and week progress (equal sources). nil for any other file.
public func claudeCodeSnapshot(limits: JSONObject, now: Date) -> SourceSnapshot? {
    guard limits["source"] as? String == claudeCodeSource else { return nil }
    return claudeFormatSnapshot(limits: limits, now: now,
                                source: UsageSource(id: claudeCodeSource, tool: "claude-code", accountLabel: ""),
                                plan: limits["plan"] as? String)
}
