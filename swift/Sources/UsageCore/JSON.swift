import Foundation

/// The limits file and settings are free-form JSON from the API: kept as
/// dictionaries (like core.py) so unknown fields pass through untouched.
public typealias JSONObject = [String: Any]

public func loadJSONObject(_ url: URL) -> JSONObject {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject
    else { return [:] }
    return obj
}

/// Atomic write, like core.save_json().
public func saveJSONObject(_ obj: JSONObject, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

/// A JSON true/false (NSNumber backed by CFBoolean), as opposed to a number.
func isJSONBool(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
}

/// A JSON integer (Python int): not a bool, not a float like 1.0.
func jsonInt(_ v: Any?) -> Int? {
    guard let n = v as? NSNumber, !isJSONBool(n) else { return nil }
    let type = String(cString: n.objCType)
    guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else { return nil }
    return n.intValue
}

/// A JSON number as Double (Python: int or float, not bool). nil for anything else.
func jsonNumber(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, !isJSONBool(n) else { return nil }
    return n.doubleValue
}

/// Python truthiness for the values core.py tests with `or`.
public func truthy(_ v: Any?) -> Bool {
    switch v {
    case nil, is NSNull: return false
    case let s as String: return !s.isEmpty
    case let n as NSNumber: return n.doubleValue != 0
    case let a as [Any]: return !a.isEmpty
    case let d as [String: Any]: return !d.isEmpty
    default: return true
    }
}

/// `limits.get(key) or {}` for a nested block.
func block(_ obj: JSONObject, _ key: String) -> JSONObject {
    obj[key] as? JSONObject ?? [:]
}

/// `(d.get(key, "") or "")` for string fields.
func string(_ obj: JSONObject, _ key: String) -> String {
    obj[key] as? String ?? ""
}
