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
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: snapshotJSON(s)), as: UTF8.self)
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
        let back = snapshot(fromJSON: snapshotJSON(s), sourceId: "codex")!
        XCTAssertEqual(back.source, s.source)
        XCTAssertEqual(back.windows, s.windows)
        XCTAssertEqual(back.plan, "plus")
        XCTAssertEqual(back.resetCredits, s.resetCredits)
        XCTAssertEqual(back.fetchedAt, s.fetchedAt)
        XCTAssertNil(snapshot(fromJSON: snapshotJSON(s), sourceId: "claude-desktop"))
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
