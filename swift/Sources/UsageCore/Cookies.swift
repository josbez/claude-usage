import CommonCrypto
import Foundation
import SQLite3

// Cookie decryption for the Claude desktop app's Chromium cookie store
// (core.py: find_cookie_db, derive_cookie_key, decrypt_cookie_value, read_cookies).

public let claudeAppSupport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude")

/// core.find_cookie_db(): newer Electron/Chromium versions moved Cookies into Network/.
public func findCookieDB(base: URL = claudeAppSupport) -> URL? {
    for candidate in [base.appendingPathComponent("Cookies"),
                      base.appendingPathComponent("Network/Cookies")]
    where FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }
    return nil
}

/// core.derive_cookie_key(): Chromium-on-macOS key for the 'v10' scheme.
public func deriveCookieKey(_ password: String) -> Data {
    let pw = Array(password.utf8)
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: 16)
    _ = pw.withUnsafeBufferPointer { p in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                             p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                             pw.count, salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    return Data(key)
}

func sha256(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
    return Data(digest)
}

/// core.decrypt_cookie_value(): the ASCII value, or nil.
public func decryptCookieValue(_ enc: Data, host: String, key: Data) -> String? {
    guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return nil }
    let body = Data(enc.dropFirst(3))
    guard body.count % kCCBlockSizeAES128 == 0, !body.isEmpty else { return nil }
    let iv = Data(repeating: 0x20, count: 16)
    var out = Data(count: body.count)
    var moved = 0
    let status = out.withUnsafeMutableBytes { o in
        body.withUnsafeBytes { b in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,   // no padding: checked below
                            k.baseAddress, key.count, v.baseAddress,
                            b.baseAddress, body.count, o.baseAddress, body.count, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    var dec = out.prefix(moved)
    guard let pad = dec.last, pad >= 1, pad <= 16, dec.count >= Int(pad),
          dec.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { return nil }
    dec = dec.dropLast(Int(pad))
    // Chromium >= v24 prefixes the value with sha256(host_key)
    let prefix = sha256(Data(host.utf8))
    if dec.count >= 32, dec.prefix(32) == prefix { dec = dec.dropFirst(32) }
    guard dec.allSatisfy({ $0 < 0x80 }) else { return nil }
    return String(data: Data(dec), encoding: .ascii)
}

public struct Cookie: Equatable {
    public let value: String
    public let domain: String
    public let path: String
}

/// One row of the cookie store, still encrypted.
public struct CookieRow: Equatable {
    public let name: String
    public let encrypted: Data
    public let host: String
    public let path: String
    public init(name: String, encrypted: Data, host: String, path: String) {
        self.name = name; self.encrypted = encrypted; self.host = host; self.path = path
    }
}

/// All rows of the cookie store, encrypted; [] when it can't be read. Works on a
/// copy: the desktop app keeps the live DB locked.
public func readCookieRows(db: URL) -> [CookieRow] {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudeusage-\(UUID().uuidString).db")
    guard (try? FileManager.default.copyItem(at: db, to: tmp)) != nil else { return [] }
    defer { try? FileManager.default.removeItem(at: tmp) }

    var handle: OpaquePointer?
    guard sqlite3_open_v2(tmp.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(handle)
        return []
    }
    defer { sqlite3_close(handle) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT name, encrypted_value, host_key, path FROM cookies",
                             -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    func text(_ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }
    var rows: [CookieRow] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let n = Int(sqlite3_column_bytes(stmt, 1))
        let enc = sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: n) } ?? Data()
        rows.append(CookieRow(name: text(0), encrypted: enc, host: text(2), path: text(3)))
    }
    return rows
}

/// Decryptable cookies by name (later rows win, like core.read_cookies).
public func decryptCookies(_ rows: [CookieRow], key: Data) -> [String: Cookie] {
    var cookies: [String: Cookie] = [:]
    for row in rows {
        if let value = decryptCookieValue(row.encrypted, host: row.host, key: key), !value.isEmpty {
            cookies[row.name] = Cookie(value: value, domain: row.host, path: row.path)
        }
    }
    return cookies
}

/// core.read_cookies(): all decryptable cookies by name.
public func readCookies(db: URL, key: Data) -> [String: Cookie] {
    decryptCookies(readCookieRows(db: db), key: key)
}

/// core.read_safe_storage_password(): via /usr/bin/security, like the Python app,
/// so the Keychain permission already granted to `security` applies here too.
public func readSafeStoragePassword() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Safe Storage", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum CookieError: Error, CustomStringConvertible {
    case noPassword, noDatabase
    public var description: String {
        switch self {
        case .noPassword: return "geen 'Claude Safe Storage' sleutel in keychain"
        case .noDatabase: return "cookie-database niet gevonden"
        }
    }
}

/// What a sessionKey lookup found.
public enum SessionKeyResult: Equatable {
    case key(String)
    /// No sessionKey cookie in the store: the desktop app is logged out.
    case loggedOut
    /// The Keychain gave no password (Deny, Esc, no item), or it doesn't decrypt the cookie.
    case noPassword
    /// An earlier Keychain request failed: not asking again yet (taak 54).
    case waiting
    case noDatabase
}

/// Why the Keychain password was requested (for the log).
public enum KeychainReadReason: String {
    case start = "start", keyChanged = "sleutel gewijzigd", retry = "opnieuw"
}

/// Keeps the cookie key in memory, so the Keychain is asked once per app start
/// instead of on every fetch (taak 54). Users who clicked "Allow" instead of
/// "Always Allow" got a password prompt every refresh. The key never touches disk.
public final class CookieKeyCache {
    public static let retryInterval: TimeInterval = 3600

    private let readPassword: () -> String
    private let now: () -> Date
    private let onRead: (KeychainReadReason) -> Void
    private var key: Data?
    private var failedAt: Date?
    private var everRead = false

    public init(readPassword: @escaping () -> String = readSafeStoragePassword,
                now: @escaping () -> Date = Date.init,
                onRead: @escaping (KeychainReadReason) -> Void = { _ in }) {
        self.readPassword = readPassword
        self.now = now
        self.onRead = onRead
    }

    /// After a failed request, allow the next lookup to ask again (refresh button).
    public func allowRetry() { failedAt = nil }

    public func sessionKey(rows: [CookieRow]) -> SessionKeyResult {
        let sessionRows = rows.filter { $0.name == "sessionKey" }
        // Logged out needs no Keychain at all: never ask for it.
        guard !sessionRows.isEmpty else { return .loggedOut }

        var reason = everRead ? KeychainReadReason.retry : .start
        if let key {
            if let value = decryptCookies(sessionRows, key: key)["sessionKey"]?.value { return .key(value) }
            // The cookie is there but our key no longer opens it: the password changed.
            self.key = nil
            reason = .keyChanged
        } else if let failedAt, now().timeIntervalSince(failedAt) < Self.retryInterval {
            return .waiting
        }

        everRead = true
        onRead(reason)
        let password = readPassword()
        guard !password.isEmpty else {
            failedAt = now()
            return .noPassword
        }
        let fresh = deriveCookieKey(password)
        guard let value = decryptCookies(sessionRows, key: fresh)["sessionKey"]?.value else {
            // A fresh password that can't decrypt won't do better next minute.
            failedAt = now()
            return .noPassword
        }
        key = fresh
        failedAt = nil
        return .key(value)
    }

    /// The sessionKey from the desktop app's cookie store.
    public func sessionKey(db: URL? = findCookieDB()) -> SessionKeyResult {
        guard let db else { return .noDatabase }
        return sessionKey(rows: readCookieRows(db: db))
    }
}

/// core.decrypt_claude_cookies() + session_key_from(): the sessionKey, "" when absent.
/// Asks the Keychain every call: only for one-off use (probe), the app uses CookieKeyCache.
public func claudeSessionKey() throws -> String {
    let password = readSafeStoragePassword()
    guard !password.isEmpty else { throw CookieError.noPassword }
    guard let db = findCookieDB() else { throw CookieError.noDatabase }
    return readCookies(db: db, key: deriveCookieKey(password))["sessionKey"]?.value ?? ""
}
