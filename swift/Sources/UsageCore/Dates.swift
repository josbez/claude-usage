import Foundation

/// core.parse_dt(): ISO 8601 as Python 3.9's datetime.fromisoformat() reads it,
/// plus a trailing "Z". Without an offset the time is local (Python's naive
/// datetime, which astimezone() treats as local).
public func parseDate(_ s: String) -> Date? {
    let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{3}|\d{6}))?)?)?(Z|[+-]\d{2}:\d{2})?$"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    else { return nil }
    func group(_ i: Int) -> String? {
        guard let r = Range(m.range(at: i), in: s) else { return nil }
        return String(s[r])
    }
    var c = DateComponents()
    c.year = Int(group(1)!); c.month = Int(group(2)!); c.day = Int(group(3)!)
    c.hour = Int(group(4) ?? "0"); c.minute = Int(group(5) ?? "0"); c.second = Int(group(6) ?? "0")
    if let frac = group(7) {
        let micro = frac.count == 3 ? Int(frac)! * 1000 : Int(frac)!
        c.nanosecond = micro * 1000
    }
    var cal = Calendar(identifier: .gregorian)
    if let tz = group(8) {
        if tz == "Z" {
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
        } else {
            let sign = tz.hasPrefix("-") ? -1 : 1
            let hm = tz.dropFirst().split(separator: ":")
            let secs = sign * (Int(hm[0])! * 3600 + Int(hm[1])! * 60)
            guard let zone = TimeZone(secondsFromGMT: secs) else { return nil }
            cal.timeZone = zone
        }
    } else {
        cal.timeZone = .current
    }
    guard c.month! >= 1, c.month! <= 12, c.day! >= 1, c.hour! < 24, c.minute! < 60, c.second! < 60,
          cal.date(from: DateComponents(year: c.year, month: c.month)) != nil,
          let date = cal.date(from: c),
          cal.component(.day, from: date) == c.day
    else { return nil }
    return date
}

/// Local calendar parts that core.py takes from astimezone().
struct LocalParts {
    let weekdayMonday0: Int
    let day: Int
    let month: Int
    let hhmm: String

    init(_ date: Date, timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.weekday, .day, .month, .hour, .minute], from: date)
        weekdayMonday0 = (c.weekday! + 5) % 7     // Calendar: Sunday = 1
        day = c.day!
        month = c.month!
        hhmm = String(format: "%02d:%02d", c.hour!, c.minute!)
    }
}

/// Python's round(x, 1): correctly rounded on the exact binary value, like printf.
func pyRound1(_ x: Double) -> Double { Double(String(format: "%.1f", x))! }

/// Python's round(x) for floats: half to even.
func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

/// Python's int() of a float: truncate toward zero.
func pyInt(_ x: Double) -> Int { Int(x.rounded(.towardZero)) }
