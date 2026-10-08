import Foundation
import XCTest
@testable import UsageCore

/// Taak 55c: Codex limits and reset credits from `codex app-server`.
final class CodexTests: XCTestCase {
    static let fixture: JSONObject = {
        let url = FixtureCase.testsDir.appendingPathComponent("Fixtures/codex-app-server-ratelimits.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! JSONObject
    }()
    let now = Date(timeIntervalSince1970: 1_791_386_000)   // 7-10-2026 ±14:13 local, before every reset
    let fetched = Date(timeIntervalSince1970: 1_791_385_990)

    func testRealResponse() {
        let parse = codexSnapshot(rateLimits: Self.fixture, fetchedAt: fetched, now: now)
        XCTAssertEqual(parse.unknown, [])
        let s = parse.snapshot!
        XCTAssertEqual(s.source, UsageSource(id: "codex", tool: "codex", accountLabel: ""))
        XCTAssertEqual(s.windows, [
            UsageWindow(id: "primary", kind: .session, utilization: 1, resetsAt: Date(timeIntervalSince1970: 1_791_396_969)),
            UsageWindow(id: "secondary", kind: .weekly, utilization: 0, resetsAt: Date(timeIntervalSince1970: 1_791_983_769)),
        ])
        XCTAssertEqual(s.plan, "plus")
        XCTAssertEqual(s.fetchedAt, fetched)
        XCTAssertEqual(s.resetCredits, ResetCredits(available: 2, nextExpiry: Date(timeIntervalSince1970: 1_792_699_229),
                                                    labels: ["Full reset (Weekly + 5 hr)", "Full reset (Weekly + 5 hr)"]))
    }

    func testNoAccountDataLeaves() {
        let s = codexSnapshot(rateLimits: Self.fixture, fetchedAt: fetched, now: now).snapshot!
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: snapshotJSON(s, origin: "app-server")), as: UTF8.self)
        for secret in ["account-id", "credit-id", "Thanks for using"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    func testFallsBackToRateLimits() {
        var r = Self.fixture
        r["rateLimitsByLimitId"] = NSNull()
        XCTAssertEqual(codexSnapshot(rateLimits: r, fetchedAt: fetched, now: now).snapshot?.windows.count, 2)
        XCTAssertNil(codexSnapshot(rateLimits: [:], fetchedAt: fetched, now: now).snapshot)
    }

    func testUnknownValuesAreReportedNotGuessed() {
        var r = Self.fixture
        var limits = (r["rateLimitsByLimitId"] as! JSONObject)["codex"] as! JSONObject
        limits["planType"] = "team"
        limits["primary"] = ["usedPercent": 3, "windowDurationMins": 60, "resetsAt": 1_791_396_969]
        limits["secondary"] = ["usedPercent": NSNull()]
        r["rateLimitsByLimitId"] = ["codex": limits]
        let parse = codexSnapshot(rateLimits: r, fetchedAt: fetched, now: now)
        XCTAssertNil(parse.snapshot?.plan)
        XCTAssertEqual(parse.snapshot?.windows.map(\.kind), [.other])
        XCTAssertEqual(parse.unknown, ["venster primary van 60 min", "venster secondary zonder usedPercent/windowDurationMins",
                                       "planType team"])
    }

    func testResetCredits() {
        func credit(_ status: String, expires: Double?, type: String = "codexRateLimits") -> JSONObject {
            ["id": "x", "resetType": type, "status": status, "expiresAt": expires.map { $0 as Any } ?? NSNull(), "title": "Full reset"]
        }
        let (c, unknown) = codexResetCredits(["availableCount": 9, "credits": [
            credit("available", expires: 1_792_000_000),
            credit("available", expires: 1_791_000_000),          // expired
            credit("redeemed", expires: 1_792_000_000),
            credit("available", expires: 1_792_000_000, type: "somethingNew"),
            credit("available", expires: nil),
        ]], now: now)
        XCTAssertEqual(c, ResetCredits(available: 2, nextExpiry: Date(timeIntervalSince1970: 1_792_000_000),
                                       labels: ["Full reset", "Full reset"]))
        XCTAssertEqual(unknown, ["reset-status redeemed", "reset-type somethingNew"])
        XCTAssertNil(codexResetCredits(["availableCount": 0, "credits": []], now: now).0)
        XCTAssertNil(codexResetCredits(NSNull(), now: now).0)
        XCTAssertEqual(codexResetCredits(["availableCount": 1], now: now).0,
                       ResetCredits(available: 1, nextExpiry: nil, labels: []))
    }

    func testSnapshotFileRoundTrip() {
        let s = codexSnapshot(rateLimits: Self.fixture, fetchedAt: fetched, now: now).snapshot!
        let back = snapshot(fromJSON: snapshotJSON(s, origin: "app-server"), sourceId: "codex")!
        XCTAssertEqual(back.source, s.source)
        XCTAssertEqual(back.windows, s.windows)
        XCTAssertEqual(back.plan, "plus")
        XCTAssertEqual(back.resetCredits, s.resetCredits)
        XCTAssertEqual(back.fetchedAt, s.fetchedAt)
        XCTAssertNil(snapshot(fromJSON: snapshotJSON(s, origin: "app-server"), sourceId: "claude-desktop"))
        XCTAssertNil(snapshot(fromJSON: ["source": "codex"], sourceId: "codex"))
    }

    func testCheckDue() {
        XCTAssertTrue(codexCheckDue(lastCheck: nil, now: now))
        XCTAssertFalse(codexCheckDue(lastCheck: now.addingTimeInterval(-299), now: now))
        XCTAssertTrue(codexCheckDue(lastCheck: now.addingTimeInterval(-300), now: now))
    }

    func testBinaryCandidates() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let paths = codexBinaryCandidates(home: home).map(\.path)
        XCTAssertEqual(paths.first, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/codex"))
        XCTAssertNil(findCodexBinary(home: URL(fileURLWithPath: "/nonexistent"), fm: FakeFM()))
    }

    final class FakeFM: FileManager {
        override func isExecutableFile(atPath path: String) -> Bool { false }
    }
}

/// The app-server runner against fake `codex` binaries (shell scripts that play the protocol).
final class CodexAppServerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fakecodex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func fake(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Answers like the real app-server: handshake, a notification, then the reply line.
    func protocolScript(reply: String) throws -> URL {
        let replyFile = dir.appendingPathComponent("reply.json")
        try reply.write(to: replyFile, atomically: true, encoding: .utf8)
        return try fake("codex", """
        [ "$1" = app-server ] || exit 9
        while IFS= read -r line; do
          case "$line" in
            *'"id":0'*) echo '{"id":0,"result":{"userAgent":"fake"}}'; echo '{"method":"remoteControl/status/changed"}' ;;
            *'"id":1'*) echo '{"method":"account/updated","params":{}}'; cat '\(replyFile.path)'; echo ;;
          esac
        done
        """)
    }

    func failure(_ r: Result<JSONObject, CodexAppServerError>) -> CodexAppServerError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    func stillRunning(_ binary: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", binary.path]
        p.standardOutput = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func testGoodAnswer() throws {
        let result = String(decoding: try JSONSerialization.data(withJSONObject: CodexTests.fixture), as: UTF8.self)
        let bin = try protocolScript(reply: #"{"id":1,"result":"# + result + "}")
        guard case .success(let r) = readCodexRateLimits(binary: bin, timeout: 5) else { return XCTFail() }
        XCTAssertEqual((r["rateLimitResetCredits"] as? JSONObject)?["availableCount"] as? Int, 2)
        XCTAssertFalse(stillRunning(bin))
    }

    func testRPCError() throws {
        let bin = try protocolScript(reply: #"{"id":1,"error":{"code":-32600,"message":"not logged in"}}"#)
        XCTAssertEqual(failure(readCodexRateLimits(binary: bin, timeout: 5)), .rpc(code: -32600, message: "not logged in"))
        XCTAssertFalse(stillRunning(bin))
    }

    func testHangTimesOutAndIsStopped() throws {
        let bin = try fake("codex", "sleep 30")
        let start = Date()
        XCTAssertEqual(failure(readCodexRateLimits(binary: bin, timeout: 1, grace: 0.5)), .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertFalse(stillRunning(bin))
    }

    func testIgnoresTerminateIsKilled() throws {
        let bin = try fake("codex", "trap '' TERM\nwhile true; do sleep 0.1; done")
        XCTAssertEqual(failure(readCodexRateLimits(binary: bin, timeout: 1, grace: 0.5)), .timeout)
        XCTAssertFalse(stillRunning(bin))
    }

    func testCrash() throws {
        let bin = try fake("codex", "exit 3")
        XCTAssertEqual(failure(readCodexRateLimits(binary: bin, timeout: 5)), .exited(3))
    }

    func testMissingBinary() {
        guard case .failure(.launch) = readCodexRateLimits(binary: dir.appendingPathComponent("nope"), timeout: 1)
        else { return XCTFail() }
    }

    func testOnlyReadsAreSent() {
        let methods = codexRequestLines(clientVersion: "x").compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? JSONObject)?["method"] as? String
        }
        XCTAssertEqual(methods, ["initialize", "initialized", "account/rateLimits/read"])
    }
}

/// Taak 55i: fallback to the last rate-limits event in Codex's session files.
final class CodexSessionFileTests: XCTestCase {
    static let events: [JSONObject] = {
        let url = FixtureCase.testsDir.appendingPathComponent("Fixtures/codex-rate-limits.jsonl")
        return try! String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! JSONObject }
    }()
    let now = parseDate("2026-10-07T13:30:00Z")!
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codexsessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRealEvent() {
        let parse = codexSessionSnapshot(event: Self.events[1], now: now)
        XCTAssertEqual(parse.unknown, [])
        let s = parse.snapshot!
        XCTAssertEqual(s.windows, [
            UsageWindow(id: "primary", kind: .session, utilization: 1, resetsAt: Date(timeIntervalSince1970: 1_791_396_969)),
            UsageWindow(id: "secondary", kind: .weekly, utilization: 0, resetsAt: Date(timeIntervalSince1970: 1_791_983_769)),
        ])
        XCTAssertEqual(s.fetchedAt, parseDate("2026-10-07T13:21:49.986Z"))
        XCTAssertEqual(s.plan, "plus")
        XCTAssertNil(s.resetCredits)   // not in session files
    }

    func testPassedResetCountsAsZero() {
        let later = Date(timeIntervalSince1970: 1_791_396_969 + 60)   // after the 5-hour reset
        let s = codexSessionSnapshot(event: Self.events[1], now: later).snapshot!
        XCTAssertEqual(s.window(.session), UsageWindow(id: "primary", kind: .session, utilization: 0, resetsAt: nil))
        XCTAssertEqual(s.window(.weekly)?.resetsAt, Date(timeIntervalSince1970: 1_791_983_769))
    }

    func testOldEventIsNoSource() {
        XCTAssertNil(codexSessionSnapshot(event: Self.events[1], now: now.addingTimeInterval(8 * 86400)).snapshot)
        XCTAssertNil(codexSessionSnapshot(event: ["type": "event_msg"], now: now).snapshot)
    }

    func line(_ obj: JSONObject) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) }

    func testReadsTheLastEventFromTheEnd() throws {
        let filler = String(repeating: #"{"type":"response_item","payload":{"text":"\#(String(repeating: "x", count: 1000))"}}"# + "\n", count: 200)
        var older = Self.events[0]; older["timestamp"] = "2026-10-07T13:00:00.000Z"
        let file = dir.appendingPathComponent("s.jsonl")
        // older event, ~200 KB filler, newest event, more filler: the event spans 64 KB block borders.
        try (line(older) + "\n" + filler + line(Self.events[1]) + "\n" + filler).write(to: file, atomically: true, encoding: .utf8)
        let ev = lastCodexRateLimitsEvent(in: file)
        XCTAssertEqual(ev?["timestamp"] as? String, "2026-10-07T13:21:49.986Z")
        // Not within the read limit: nothing (rather than reading a huge file whole).
        XCTAssertNil(lastCodexRateLimitsEvent(in: file, maxBytes: 64 << 10))
        let empty = dir.appendingPathComponent("e.jsonl")
        try "".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertNil(lastCodexRateLimitsEvent(in: empty))
        XCTAssertNil(lastCodexRateLimitsEvent(in: dir.appendingPathComponent("missing.jsonl")))
    }

    func testEventOnTheFirstLineWithoutNewline() throws {
        let file = dir.appendingPathComponent("one.jsonl")
        try line(Self.events[0]).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(lastCodexRateLimitsEvent(in: file)?["timestamp"] as? String, "2026-10-07T13:16:09.925Z")
    }

    func testLatestFileInRecentDayFolders() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let fm = FileManager.default
        func put(_ day: String, _ name: String, age: TimeInterval) throws {
            let d = dir.appendingPathComponent(day)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            let f = d.appendingPathComponent(name)
            try "x".write(to: f, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: f.path)
        }
        try put("2026/10/07", "today.jsonl", age: 600)
        try put("2026/10/05", "longrunning.jsonl", age: 60)   // older folder, written more recently
        try put("2026/10/07", "notes.txt", age: 1)
        try put("2026/09/20", "ancient.jsonl", age: 1)       // outside the 8 days
        XCTAssertEqual(latestCodexSessionFile(root: dir, now: now, calendar: cal)?.lastPathComponent, "longrunning.jsonl")
        XCTAssertNil(latestCodexSessionFile(root: dir.appendingPathComponent("nope"), now: now, calendar: cal))
    }

    /// Installed and logged in (decided 8-10-2026): a binary and auth.json; either missing = no source.
    func testInstalledNeedsBinaryAndLogin() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("codex-installed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let binary = home.appendingPathComponent(".local/bin/codex")
        let auth = home.appendingPathComponent(".codex/auth.json")
        // The real ChatGPT.app may exist on this Mac: only test the home-relative candidates.
        let systemBinary = findCodexBinary(home: home) != nil
        XCTAssertEqual(codexInstalled(home: home), false)          // no auth.json

        try Data("{}".utf8).write(to: auth)
        XCTAssertEqual(codexInstalled(home: home), systemBinary)   // auth, binary only if the system has one
        try Data().write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertTrue(codexInstalled(home: home))

        try fm.removeItem(at: auth)                                 // logged out
        XCTAssertFalse(codexInstalled(home: home))
    }
}
