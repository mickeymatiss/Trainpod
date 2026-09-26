import Foundation

@main struct DiagnosticScopeChecks {
    static func event(_ sequence: Int, _ code: String, _ session: String?) -> [String: Any] {
        var row: [String: Any] = ["sequence": sequence, "uptimeMs": sequence * 10,
            "unixTimeMs": 1000 + sequence * 10, "eventCode": code, "level": "INFO", "transactionId": "1-1"]
        if let session { row["sessionId"] = session }
        return row
    }
    static func render(_ phone: [[String: Any]], _ device: [[String: Any]] = []) throws -> String {
        try DiagnosticInterleave.render(JSONSerialization.data(withJSONObject:
            ["device": ["metadata": ["bootId": 1], "deviceLogs": device], "phoneLogs": phone, "collectedAtUnixMs": 6000]))
    }
    static func headings(_ text: String) -> [String] { text.components(separatedBy: "\n").filter { $0.hasPrefix("TRANSACTION ") } }
    static func main() throws {
        // Same textual transaction, interleaved scope A and B. Combining these
        // fragments would fabricate a successful transaction that neither proves.
        let mixed = try render([event(1, "DEVICE_DATA_REQUEST_RECEIVED", "a"), event(2, "DATA_APPLIED_ACK_RECEIVED", "b")],
                               [event(1, "DATA_APPLIED", "a"), event(2, "DISPLAY_UPDATED", "b")])
        precondition(headings(mixed).count == 2, "Different connection sessions were conflated")
        precondition(!headings(mixed).contains { $0.contains("SUCCESS") })
        let same = try render([event(1, "DATA_APPLIED_ACK_RECEIVED", "a")],
                              [event(1, "DATA_APPLIED", "a"), event(2, "DISPLAY_UPDATED", "a")])
        precondition(headings(same).count == 1 && headings(same)[0].contains("SUCCESS"))
        // Missing evidence is not guessed from matching boot/request text.
        let unknown = try render([event(1, "DATA_APPLIED_ACK_RECEIVED", nil)],
                                 [event(1, "DATA_APPLIED", nil), event(2, "DISPLAY_UPDATED", nil)])
        precondition(!headings(unknown).contains { $0.contains("SUCCESS") })
        precondition(unknown.contains("session=unassigned; events not joined"))

        let unknownSpans = DiagnosticInterleave.normalizedEvents([
            "device": [:], "phoneLogs": [event(1, "FETCH_STARTED", nil), event(2, "FETCH_SUCCESS", nil)]])
        precondition(DiagnosticInterleave.cleaned(unknownSpans).allSatisfy { $0.references.count == 1 },
                     "Missing session evidence must not pair unknown transactions in the timeline")

        // Five retained transactions means five scoped transactions, not one
        // bucket containing arbitrary devices' identical boot/request strings.
        let log = PhoneDiagnosticLog()
        for id in ["a", "b", "c", "d", "e", "f"] {
            log.setSession(id)
            log.retainTransaction("1-1")
            log.record("RETAINED", transactionId: "1-1")
        }
        for _ in 0..<520 { log.record("NOISE") }
        let retained = log.snapshot().filter { $0.eventCode == "RETAINED" }
        precondition(retained.map(\.sessionId) == ["b", "c", "d", "e", "f"])
        // A late task keeps the session captured when its request began, even
        // after another device becomes the logger's current session.
        PhoneDiagnosticContext.$sessionId.withValue("old") {
            PhoneDiagnosticContext.$transactionId.withValue("1-1") {
                log.setSession("new")
                precondition(log.currentSessionId == "old")
                log.record("LATE_TASK")
            }
        }
        precondition(log.snapshot().last!.sessionId == "old")
        precondition(log.currentSessionId == "new")
        if CommandLine.arguments.count > 1 { try mixed.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8) }
        print("PASS diagnostic session-scoped reconstruction, legacy known-session grouping, explicit unassigned evidence, scoped retention")
    }
}
