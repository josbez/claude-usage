import Foundation

/// Tally form for feedback and ideas (taak 56). Hidden fields: version, macos, arch, lang.
public let feedbackFormURL = "https://tally.so/r/9NNGAX"

/// The form URL with the four hidden fields filled in. Only these four: never
/// account, email, organization or usage numbers.
public func feedbackURL(version: String, os: String, arch: String, lang: String) -> URL {
    var c = URLComponents(string: feedbackFormURL)!
    c.queryItems = [URLQueryItem(name: "version", value: version),
                    URLQueryItem(name: "macos", value: os),
                    URLQueryItem(name: "arch", value: arch),
                    URLQueryItem(name: "lang", value: lang)]
    // URLComponents leaves "+" alone, which a form reads as a space
    c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return c.url!
}

/// "15.1" or "15.1.2" from the OS version (no patch when it is 0).
public func macOSVersionString(_ v: OperatingSystemVersion) -> String {
    v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)"
                        : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}
