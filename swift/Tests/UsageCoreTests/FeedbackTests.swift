import XCTest
@testable import UsageCore

final class FeedbackTests: XCTestCase {
    private func items(_ url: URL) -> [String: String] {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
    }

    func testFillsTheFourHiddenFields() {
        let url = feedbackURL(version: "3.4", os: "15.1", arch: "arm64", lang: "nl")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://tally.so/r/9NNGAX?"))
        XCTAssertEqual(items(url), ["version": "3.4", "macos": "15.1", "arch": "arm64", "lang": "nl"])
    }

    func testOnlyTheFourFieldsAreSent() {
        let url = feedbackURL(version: "dev", os: "11.7.10", arch: "x86_64", lang: "en")
        XCTAssertEqual(Set(items(url).keys), ["version", "macos", "arch", "lang"])
        XCTAssertEqual(url.host, "tally.so")
    }

    func testValuesAreEscaped() {
        let url = feedbackURL(version: "3.4 beta+1&x=y", os: "15.1", arch: "arm64", lang: "en")
        XCTAssertEqual(items(url)["version"], "3.4 beta+1&x=y")
        XCTAssertEqual(items(url).count, 4)
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertFalse(url.absoluteString.contains(" "))
    }

    func testMacOSVersionString() {
        XCTAssertEqual(macOSVersionString(OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)), "15.1")
        XCTAssertEqual(macOSVersionString(OperatingSystemVersion(majorVersion: 11, minorVersion: 7, patchVersion: 10)), "11.7.10")
    }
}
