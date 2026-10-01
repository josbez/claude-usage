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

/// core.read_cookies(): all decryptable cookies by name. Works on a copy: the
/// desktop app keeps the live DB locked.
public func readCookies(db: URL, key: Data) -> [String: Cookie] {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudeusage-\(UUID().uuidString).db")
    guard (try? FileManager.default.copyItem(at: db, to: tmp)) != nil else { return [:] }
    defer { try? FileManager.default.removeItem(at: tmp) }

    var handle: OpaquePointer?
    guard sqlite3_open_v2(tmp.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(handle)
        return [:]
    }
    defer { sqlite3_close(handle) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT name, encrypted_value, host_key, path FROM cookies",
                             -1, &stmt, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_finalize(stmt) }

    func text(_ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }
    var cookies: [String: Cookie] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        let n = Int(sqlite3_column_bytes(stmt, 1))
        let enc = sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: n) } ?? Data()
        let host = text(2)
        if let value = decryptCookieValue(enc, host: host, key: key), !value.isEmpty {
            cookies[text(0)] = Cookie(value: value, domain: host, path: text(3))
        }
    }
    return cookies
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

/// core.decrypt_claude_cookies() + session_key_from(): the sessionKey, "" when absent.
public func claudeSessionKey() throws -> String {
    let password = readSafeStoragePassword()
    guard !password.isEmpty else { throw CookieError.noPassword }
    guard let db = findCookieDB() else { throw CookieError.noDatabase }
    return readCookies(db: db, key: deriveCookieKey(password))["sessionKey"]?.value ?? ""
}
