import Foundation
import XCTest
@testable import UsageCore

/// Fase 3 parity: notifications and history.
final class NotifyParityTests: FixtureCase {
    func testColorForPct() {
        for c in list("color_for_pct") {
            let (r, g, b) = colorForPct((c["in"] as! NSNumber).doubleValue)
            XCTAssertEqual([r, g, b], c["out"] as! [Int], "\(c)")
        }
    }

    func testWindowKey() {
        for c in list("window_key") {
            XCTAssertEqual(windowKey(c["in"] as! String), c["out"] as! String, "\(c)")
        }
    }

    func testDueNotifications() {
        for c in list("due_notifications") {
            let (notes, state) = formatter.dueNotifications(c["limits"] as! JSONObject,
                                                            state: c["state"] as! JSONObject,
                                                            lang: c["lang"] as! String)
            assertSame(notes.map { $0.asJSON }, c["notes"], "\(c)")
            assertSame(state, c["new_state"], "\(c)")
        }
    }

    func testHistoryRecord() {
        for c in list("history_record") {
            assertSame(historyRecord(c["in"] as! JSONObject), c["out"], "\(c)")
        }
    }

    func testHistoryPath() {
        for c in list("history_path") {
            XCTAssertEqual(historyPath(c["in"] as! String, base: URL(fileURLWithPath: "/base"))?
                .lastPathComponent, c["out"] as? String, "\(c)")
        }
    }

    func testAppendHistoryWritesOneLinePerRecord() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let rec: JSONObject = ["ts": "2026-10-01T10:00:00+00:00", "five_hour": ["utilization": 12]]
        let path = try appendHistory(rec, base: base)
        try appendHistory(rec, base: base)
        XCTAssertEqual(path.lastPathComponent, "2026-10.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let parsed = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! JSONObject
        assertSame(parsed, rec, "round trip")
    }
}
