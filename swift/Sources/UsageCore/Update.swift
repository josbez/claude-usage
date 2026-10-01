import CryptoKit
import Foundation

// Updates: GitHub release check and signature verification (core.py). Downloading
// and installing is glue in the app (Updater.swift).

public let updateAPIURL = URL(string: "https://api.github.com/repos/josbez/claude-usage/releases/latest")!
public let updateCheckInterval: TimeInterval = 24 * 3600
public let dmgAsset = "ClaudeUsage.dmg"
public let sigAsset = dmgAsset + ".sig"

/// Ed25519 public key for release signatures — the same key as core.py, so
/// releases signed for the Python app are accepted here too. The private key
/// lives only on the release machine, never in git.
public let updatePublicKeyHex = "cd50f6dc348c4c0b3170df3c4204cb6b7adabb92c11a798116127c02d207cc66"

/// core.parse_version(): "v1.10.2" -> [1, 10, 2]; anything else (pre-releases, "dev") -> nil.
public func parseVersion(_ v: Any?) -> [Int]? {
    guard var s = v as? String else { return nil }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
    else { return nil }
    var nums = parts.map { Int($0)! }
    while nums.count > 1 && nums.last == 0 { nums.removeLast() }   // 1.2 == 1.2.0
    return nums
}

/// core.is_newer()
public func isNewer(_ candidate: String, than current: String) -> Bool {
    guard let c = parseVersion(candidate), let cur = parseVersion(current) else { return false }
    return c.lexicographicallyPrecedes(cur) == false && c != cur
}

/// core.parse_release(): what we need from a GitHub releases/latest response, or nil.
public func parseRelease(_ obj: Any?) -> [String: String]? {
    guard let o = obj as? JSONObject, !truthy(o["draft"]), !truthy(o["prerelease"]) else { return nil }
    let tag = o["tag_name"] as? String ?? ""
    guard parseVersion(tag) != nil else { return nil }
    var assets: [String: String] = [:]
    for item in o["assets"] as? [Any] ?? [] {
        if let a = item as? JSONObject, let name = a["name"] as? String {
            assets[name] = a["browser_download_url"] as? String ?? ""
        }
    }
    var version = Substring(tag)
    while let f = version.first, f == "v" || f == "V" { version.removeFirst() }
    return ["version": String(version), "html_url": o["html_url"] as? String ?? "",
            "dmg_url": assets[dmgAsset] ?? "", "sig_url": assets[sigAsset] ?? ""]
}

/// core.update_check_due()
public func updateCheckDue(_ state: JSONObject, now: Date, interval: TimeInterval = updateCheckInterval) -> Bool {
    guard let last = state["last_check"] as? String, !last.isEmpty else { return true }
    guard let dt = parseDate(last) else { return true }
    return now.timeIntervalSince(dt) >= interval
}

/// core.verify_release_signature(): base64 Ed25519 signature over the whole file.
public func verifyReleaseSignature(_ data: Data, _ sigText: String,
                                   publicKeyHex: String = updatePublicKeyHex) -> Bool {
    let b64 = sigText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyBytes = hexData(publicKeyHex),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
          b64.range(of: #"^[A-Za-z0-9+/]*={0,2}$"#, options: .regularExpression) != nil,
          let sig = Data(base64Encoded: b64)
    else { return false }
    return key.isValidSignature(sig, for: data)
}

public func hexData(_ s: String) -> Data? {
    guard s.count % 2 == 0 else { return nil }
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
        data.append(b)
        i = j
    }
    return data
}

/// An update failure: a STRINGS key (without "err_") plus values, so the app
/// can show it in the user's language; `description` is Dutch, for the log.
public struct UpdateError: Error, CustomStringConvertible {
    public let key: String
    public let values: [String: Any]
    public let strings: Strings?

    public init(_ key: String, _ values: [String: Any] = [:], strings: Strings? = nil) {
        self.key = key
        self.values = values
        self.strings = strings
    }

    public func message(_ lang: String) -> String {
        strings?.t("err_" + key, lang, values) ?? key
    }

    public var description: String { message("nl") }
}
