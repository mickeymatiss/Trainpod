import Foundation

@main struct DiagnosticRenderChecks {
    static func event(_ sequence: Int, _ code: String, _ tx: String = "1-1", _ session: String = "a") -> [String: Any] {
        ["sequence": sequence, "uptimeMs": sequence * 10, "unixTimeMs": 1000 + sequence * 10,
         "timestampSynced": true, "eventCode": code, "level": "INFO", "transactionId": tx, "sessionId": session]
    }
    static func report(_ device: [[String: Any]], _ phone: [[String: Any]], serial: String? = nil) throws -> String {
        var root: [String: Any] = ["device": ["metadata": ["bootId": 1], "deviceLogs": device],
                                   "phoneLogs": phone, "collectedAtUnixMs": 9000]
        // Serial-only evidence may be available alongside an export, but the
        // current export schema provides no transaction-to-render-generation join.
        // This annotation is deliberately NOT a new supported export field.
        if let serial { root["testExternalSerialEvidence"] = serial }
        return try DiagnosticInterleave.render(JSONSerialization.data(withJSONObject: root))
    }
    static func main() throws {
        let applied = event(1, "DATA_APPLIED"), ack = event(1, "DATA_APPLIED_ACK_RECEIVED")
        let success = try report([applied, event(2, "DISPLAY_UPDATED")], [ack])
        precondition(success.contains("TRANSACTION 1-1 — SUCCESS"))
        let missing = try report([applied], [ack])
        precondition(missing.contains("DISPLAY COMPLETION UNKNOWN"), "Missing completion was overstated as a render failure")
        precondition(!missing.contains("DISPLAY / RENDER FAILURE"))
        let serialSupersession = try report([applied], [ack], serial: "[INFO] RENDER_SUPERSEDED generation=42 elapsed=8ms")
        precondition(serialSupersession.contains("DISPLAY COMPLETION UNKNOWN"))
        precondition(!serialSupersession.contains("— SUPERSEDED"), "Unjoined serial evidence cannot prove a transaction outcome")
        let truncated = try report([], [ack])
        precondition(truncated.contains("INCOMPLETE / IN PROGRESS") && !truncated.contains("RENDER FAILURE"))
        let overlap = try report([applied, event(2, "DATA_APPLIED", "1-2"), event(3, "DISPLAY_UPDATED", "1-2")],
                                 [ack, event(2, "DATA_APPLIED_ACK_RECEIVED", "1-2")])
        precondition(overlap.contains("TRANSACTION 1-1 — APPLIED / ACKNOWLEDGED — DISPLAY COMPLETION UNKNOWN"))
        precondition(overlap.contains("TRANSACTION 1-2 — SUCCESS"))
        let scopes = try report([applied, event(2, "DISPLAY_UPDATED", "1-1", "b")], [ack])
        precondition(scopes.contains("DISPLAY COMPLETION UNKNOWN") && !scopes.contains("TRANSACTION 1-1 — SUCCESS"))
        let failed = try report([event(1, "PAYLOAD_PARSE_FAILURE")], [])
        precondition(failed.contains("DEVICE PAYLOAD PARSE FAILURE"), "Explicit retained failures must remain visible")
        if CommandLine.arguments.count > 1 {
            try [success, missing, serialSupersession, truncated, overlap, scopes, failed].joined(separator: "\n=== NEXT FIXTURE ===\n")
                .write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
        print("PASS render evidence: confirmed completion, missing/truncated evidence, unjoined serial supersession, overlap, scoped IDs, explicit parse failure")
    }
}
