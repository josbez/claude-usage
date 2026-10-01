import Foundation

/// All user-facing text, loaded from strings.json (exported from core.STRINGS by
/// scripts/swift-fixtures.py — never edit the JSON by hand).
public struct Strings {
    public let table: [String: [String: String]]
    public let days: [String: [String]]
    public let months: [String: [String]]
    public let defaultLang: String

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = obj["strings"] as? [String: [String: String]],
              let days = obj["days"] as? [String: [String]],
              let months = obj["months"] as? [String: [String]],
              let defaultLang = obj["default_lang"] as? String
        else { throw CocoaError(.fileReadCorruptFile) }
        self.table = table
        self.days = days
        self.months = months
        self.defaultLang = defaultLang
    }

    /// core.t(): unknown language falls back to the default, unknown key to the
    /// default language's text, then to the key itself.
    public func t(_ key: String, _ lang: String, _ kw: [String: Any] = [:]) -> String {
        let fallback = table[defaultLang] ?? [:]
        let text = (table[lang] ?? fallback)[key] ?? fallback[key] ?? key
        return kw.isEmpty ? text : Strings.format(text, kw)
    }

    public func dayNames(_ lang: String) -> [String] { days[lang] ?? days[defaultLang] ?? [] }
    public func monthNames(_ lang: String) -> [String] { months[lang] ?? months[defaultLang] ?? [] }

    /// The subset of Python's str.format() that STRINGS uses: {name} and {name:02d}.
    static func format(_ text: String, _ kw: [String: Any]) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"),
              let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let field = rest[rest.index(after: open)..<close]
            let parts = field.split(separator: ":", maxSplits: 1)
            let name = String(parts.first ?? "")
            if let value = kw[name] {
                if parts.count == 2, parts[1] == "02d", let n = value as? Int {
                    out += String(format: "%02d", n)
                } else {
                    out += "\(value)"
                }
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// core.language_from(): macOS preferred languages -> "nl" or "en".
/// Only the first (= the user's chosen) language counts.
public func languageFrom(_ preferred: [String], defaultLang: String = "en") -> String {
    guard let first = preferred.first?.lowercased() else { return defaultLang }
    let base = first.split(separator: "-").first.map(String.init) ?? first
    return (base.split(separator: "_").first.map(String.init) ?? base) == "nl" ? "nl" : defaultLang
}
