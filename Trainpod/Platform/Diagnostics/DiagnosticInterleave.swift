import Foundation

/// Presentation only: never mutates the raw JSON or acknowledges a device export.
nonisolated enum DiagnosticInterleave {
    struct Event {
        let source: String
        let sequence: Int64
        let uptime: Int64
        let session: String
        let boot: String?
        let code: String
        let level: String
        let value1: Int64
        let value2: Int64
        let context: String
        let transaction: String?
        let chunk: Int64?
        let chunks: Int64?
        let bytes: Int64?
        let writeMode: String?
        let duration: Int64?
        let errorCode: String?
        var unix: Int64?
        var timestampSource: String
        var id: String { "\(source)#\(sequence)" }
        var important: Bool {
            level == "WARN" || level == "ERROR" || code.contains("TIMEOUT") ||
            code.contains("RESET") || code.hasSuffix("FAILURE") || code.hasSuffix("FAILED") ||
            ["BOOT_START", "BOOT_READY", "STARTUP_COMPLETE", "BLE_CONNECTED", "BLE_DISCONNECTED",
             "DATA_REQUEST_SENT", "DEVICE_DATA_REQUEST_RECEIVED", "FETCH_STARTED", "FETCH_SUCCESS",
             "TIME_SYNC_RECEIVED", "TIME_SYNC_UPDATED", "DIAGNOSTIC_EXPORT_REQUESTED",
             "BLE_RESPONSE_BEGIN", "BLE_RESPONSE_QUEUED", "BLE_RESPONSE_WRITE_CONFIRMED",
             "RESPONSE_RX_STARTED", "RESPONSE_RX_COMPLETE", "PAYLOAD_PARSE_SUCCESS", "DATA_APPLIED",
             "DISPLAY_UPDATED", "DATA_APPLIED_ACK_RECEIVED"].contains(code)
        }
    }
    struct Line {
        let event: Event
        var code: String
        var detail = ""
        var references: [String]
        var missing = false
        var count = 1
        var firstUptime: Int64
    }
    private struct Sync {
        let uptime: Int64
        let sequence: Int64
        let offset: Int64
    }
    private struct Pair {
        let start: String
        let ends: [String]
        let label: String
        let quantity: String?
    }
    private static let pairs = [
        Pair(start: "RESPONSE_RX_STARTED", ends: ["RESPONSE_RX_COMPLETE", "RESPONSE_RX_FAILED"], label: "RESPONSE_RX_COMPLETE", quantity: "bytes"),
        Pair(start: "PAYLOAD_PARSE_STARTED", ends: ["PAYLOAD_PARSE_SUCCESS", "PAYLOAD_PARSE_FAILURE"], label: "PAYLOAD_PARSE_SUCCESS", quantity: nil),
        Pair(start: "FETCH_STARTED", ends: ["FETCH_SUCCESS", "FETCH_FAILURE"], label: "FETCH_SUCCESS", quantity: nil),
        Pair(start: "DISPLAY_UPDATE_START", ends: ["DISPLAY_UPDATE_COMPLETE"], label: "DISPLAY_UPDATED", quantity: nil),
        Pair(start: "PAYLOAD_RX_START", ends: ["PAYLOAD_RX_COMPLETE", "PAYLOAD_PARSE_FAILURE"], label: "PAYLOAD_RECEIVED", quantity: "bytes"),
        Pair(start: "PAYLOAD_BUILD_STARTED", ends: ["PAYLOAD_BUILD_COMPLETE", "PAYLOAD_BUILD_FAILED"], label: "PAYLOAD_BUILT", quantity: "bytes"),
        Pair(start: "BLE_SEND_STARTED", ends: ["BLE_SEND_COMPLETE", "BLE_WRITE_COMPLETED", "BLE_SEND_FAILED"], label: "BLE_WRITE_COMPLETED", quantity: "bytes"),
        Pair(start: "BLE_RESPONSE_SEND_START", ends: ["BLE_RESPONSE_SEND_COMPLETE", "BLE_RESPONSE_SEND_FAILED"], label: "BLE_WRITE_COMPLETED", quantity: nil),
        Pair(start: "STATION_RESOLUTION_STARTED", ends: ["STATION_RESOLUTION_SUCCESS", "STATION_RESOLUTION_FAILURE"], label: "STATION_RESOLVED", quantity: "count"),
        Pair(start: "API_FETCH_STARTED", ends: ["API_FETCH_SUCCESS", "API_FETCH_FAILURE"], label: "API_FETCH_SUCCESS", quantity: nil),
        Pair(start: "LOCATION_REQUEST_STARTED", ends: ["LOCATION_SUCCESS", "LOCATION_FAILURE"], label: "LOCATION_SUCCESS", quantity: nil),
        Pair(start: "BLE_INIT_START", ends: ["BLE_INIT_COMPLETE"], label: "BLE_INIT_COMPLETE", quantity: nil)
    ]
    private static func number(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private static func session(_ value: Any?) -> String {
        let id = (value as? String ?? "").lowercased()
        return id.isEmpty || id == "00000000" ? "unassigned" : id
    }
    private static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

    static func compactRows(_ device: [String: Any]) -> [[String: Any]] {
        let columns = device["compactDeviceColumns"] as? [String] ?? []
        guard !columns.isEmpty else { return [] }
        return ((device["deviceChunkLogs"] as? [[Any]] ?? []) + (device["deviceTransactionLogs"] as? [[Any]] ?? [])).compactMap { row in
            guard row.count == columns.count, Set(columns).count == columns.count else { return nil }
            return Dictionary(uniqueKeysWithValues: zip(columns, row))
        }
    }
    static func normalizedEvents(_ root: [String: Any]) -> [Event] {
        let device = dictionary(root["device"])
        let metadata = dictionary(device["metadata"])
        let boot = number(metadata["bootId"]).map(String.init)
        // Error ring can retain older events no longer in the general ring. Deduplicate by sequence.
        var deviceRows: [Int64: [String: Any]] = [:]
        for row in compactRows(device) + (device["deviceErrors"] as? [[String: Any]] ?? []) + (device["deviceLogs"] as? [[String: Any]] ?? []) {
            if let seq = number(row["sequence"]) { deviceRows[seq] = row }
        }
        let rows = deviceRows.sorted { $0.key < $1.key }.map(\.value)
        var syncs: [Sync] = rows.compactMap { row in
            guard ["TIME_SYNC_RECEIVED", "TIME_SYNC_UPDATED"].contains(row["eventCode"] as? String ?? ""),
                  let seq = number(row["sequence"]), let uptime = number(row["deviceUptimeMsAtSync"]),
                  let unix = number(row["phoneUnixTimeMs"]), unix > 0 else { return nil }
            return Sync(uptime: uptime, sequence: seq, offset: unix-uptime)
        }
        if let uptime = number(metadata["deviceUptimeMsAtSync"]),
           let unix = number(metadata["phoneUnixTimeMs"]), unix > 0,
           !syncs.contains(where: { $0.uptime == uptime && $0.offset == unix-uptime }) {
            // Unknown sequence: applies only strictly after this uptime. Recorded timestamps
            // remain authoritative for older synced rows if their anchor has rolled out.
            syncs.append(Sync(uptime: uptime, sequence: .max, offset: unix-uptime))
        }
        syncs.sort { ($0.uptime, $0.sequence) < ($1.uptime, $1.sequence) }
        let sharedSessions = Set(rows.map { session($0["sessionId"]) }.filter { $0 != "unassigned" })
        var result: [Event] = []
        for (source, sourceRows) in [("DEVICE", rows), ("PHONE", root["phoneLogs"] as? [[String: Any]] ?? [])] {
            for row in sourceRows {
                guard let seq = number(row["sequence"]), let uptime = number(row["uptimeMs"]),
                      let code = row["eventCode"] as? String else { continue }
                let id = session(row["sessionId"])
                let recorded = number(row["unixTimeMs"]).flatMap { $0 > 0 ? $0 : nil }
                var unix = recorded
                var origin = source == "PHONE" ? "phone_wall_clock" : "recorded_sync_epoch"
                if source == "DEVICE" {
                    if let anchor = syncs.last(where: { $0.uptime < uptime || ($0.uptime == uptime && $0.sequence <= seq) }) {
                        let derived = uptime + anchor.offset
                        // A missing intermediate sync must not replace an explicitly recorded offset.
                        if row["timestampSynced"] as? Bool == true, let recorded, recorded != derived {
                            unix = recorded
                        } else { unix = derived; origin = "sync_epoch" }
                    } else if row["timestampSynced"] as? Bool == true, recorded != nil {
                        origin = "recorded_sync_epoch"
                    } else if let first = syncs.first {
                        unix = uptime + first.offset; origin = "inferred_from_first_sync"
                    } else { unix = nil; origin = "unsynchronized" }
                }
                result.append(Event(source: source, sequence: seq, uptime: uptime, session: id,
                    boot: (row["transactionId"] as? String)?.split(separator: "-").first.map(String.init) ?? (source == "DEVICE" || sharedSessions.contains(id) ? boot : nil),
                    code: code, level: row["level"] as? String ?? "INFO",
                    value1: number(row["value1"]) ?? 0, value2: number(row["value2"]) ?? 0,
                    context: row["currentState"] as? String ?? "",
                    transaction: row["transactionId"] as? String,
                    chunk: number(row["chunk"]) ?? (code == "RESPONSE_RX_CHUNK" ? ((number(row["value1"]) ?? 0) >> 16) & 65535 : nil),
                    chunks: number(row["chunks"]) ?? (code == "RESPONSE_RX_CHUNK" ? (number(row["value1"]) ?? 0) & 65535 : code == "RESPONSE_RX_COMPLETE" || code == "RESPONSE_RX_STARTED" ? number(row["value2"]) : nil),
                    bytes: number(row["bytes"]) ?? (code == "RESPONSE_RX_CHUNK" ? number(row["value2"]) : ["RESPONSE_RX_COMPLETE", "RESPONSE_RX_STARTED", "DATA_APPLIED"].contains(code) ? number(row["value1"]) : nil),
                    writeMode: row["writeMode"] as? String,
                    duration: number(row["durationMs"]) ?? (code == "DISPLAY_UPDATED" ? number(row["value1"]) : nil),
                    errorCode: row["errorCode"] as? String,
                    unix: unix, timestampSource: origin))
            }
        }
        let sorted = result.sorted {
            if $0.unix != $1.unix { return ($0.unix ?? .max) < ($1.unix ?? .max) }
            // Base tie order; the merge below additionally respects known device-request causality.
            if $0.source != $1.source { return $0.source == "PHONE" }
            return $0.sequence < $1.sequence
        }
        var ordered: [Event] = []
        var cursor = 0
        while cursor < sorted.count {
            var end = cursor+1
            while end < sorted.count && sorted[end].unix == sorted[cursor].unix { end += 1 }
            let group = Array(sorted[cursor..<end])
            if sorted[cursor].unix == nil { ordered += group; cursor = end; continue }
            let phone = group.filter { $0.source == "PHONE" }, device = group.filter { $0.source == "DEVICE" }
            var p = 0, d = 0
            while p < phone.count || d < device.count {
                // Drain device predecessors before a same-millisecond phone receipt. Keep
                // per-source sequence intact; phone sends otherwise precede device receipts.
                let requestBeforeReceipt = p < phone.count && phone[p].code == "DEVICE_DATA_REQUEST_RECEIVED" &&
                    d < device.count && device[d...].contains { $0.code == "DATA_REQUEST_SENT" && $0.session == phone[p].session }
                if d < device.count && (p == phone.count || requestBeforeReceipt) { ordered.append(device[d]); d += 1 }
                else { ordered.append(phone[p]); p += 1 }
            }
            cursor = end
        }
        return ordered
    }

    static func cleaned(_ events: [Event]) -> [Line] {
        var lines = events.map { Line(event: $0, code: $0.code, references: [$0.id], firstUptime: $0.uptime) }
        var hidden = Set<Int>()
        var matches: [Int: Int] = [:]
        // Pair in source sequence order, never wall-clock order (offsets may change).
        let indices = events.indices.sorted {
            (events[$0].source, events[$0].sequence) < (events[$1].source, events[$1].sequence)
        }
        for pair in pairs {
            var pending: [String: [Int]] = [:]
            for i in indices {
                let event = events[i]
                let key = "\(event.source)|\(event.boot ?? "?")|\(event.session)|\(event.transaction ?? "-")"
                if event.code == pair.start { pending[key, default: []].append(i); continue }
                guard pair.ends.contains(event.code) else { continue }
                let candidates = pending[key] ?? []
                // Without operation IDs, overlapping API requests cannot be paired safely.
                guard candidates.count == 1, let start = candidates.first,
                      event.uptime >= events[start].uptime else {
                    if candidates.count > 1 { lines[i].detail = "duration unknown: overlapping starts" }
                    continue
                }
                pending[key] = []
                matches[start] = i
                lines[i].detail = "duration=\(event.uptime-events[start].uptime)ms"
                lines[i].references.insert(events[start].id, at: 0)
                if !event.important {
                    lines[i].code = pair.label
                    if let quantity = pair.quantity { lines[i].detail = "\(quantity)=\(event.value1) " + lines[i].detail }
                }
                if !events[start].important { hidden.insert(start) }
            }
            for starts in pending.values {
                for i in starts { lines[i].missing = true }
            }
        }
        // Retain one transport span instead of the redundant response wrapper span.
        for (start, end) in matches where events[start].code == "BLE_RESPONSE_SEND_START" {
            if let transport = matches.sorted(by: { events[$0.key].sequence < events[$1.key].sequence }).first(where: { innerStart, innerEnd in
                events[innerStart].code == "BLE_SEND_STARTED" && events[innerStart].source == events[start].source &&
                events[innerStart].session == events[start].session && events[innerStart].transaction == events[start].transaction &&
                events[innerStart].sequence > events[start].sequence && events[innerEnd].sequence < events[end].sequence &&
                events[innerEnd].code == "BLE_SEND_COMPLETE"
            }), !events[end].important {
                hidden.insert(end)
                lines[transport.value].references += [events[start].id, events[end].id]
            }
        }
        let routine = Set(["BLE_ADVERTISING_START", "BLE_ADVERTISING_RESTART", "BLE_ADVERTISING_STOP",
            "BLE_RESPONSE_CHUNK_WRITE", "BLE_RESPONSE_CHUNK_WRITE_CONFIRMED", "RESPONSE_RX_CHUNK"])
        var output: [Line] = []
        for i in lines.indices where !hidden.contains(i) {
            var line = lines[i]
            if routine.contains(line.event.code) && !line.event.important { continue }
            if line.code == "DISPLAY_UPDATED", !line.event.important, let last = output.last,
               last.code == line.code, !last.event.important, last.event.session == line.event.session,
               last.event.transaction == nil, line.event.transaction == nil,
               last.event.value1 == line.event.value1, last.event.value2 == line.event.value2,
               line.event.uptime >= last.event.uptime, line.event.uptime-last.firstUptime <= 10000 {
                line.count = last.count+1; line.firstUptime = last.firstUptime
                line.references = last.references + line.references
                line.detail = "×\(line.count) over \(String(format: "%.1f", Double(line.event.uptime-line.firstUptime)/1000))s"
                output.removeLast()
            }
            output.append(line)
        }
        return output
    }

    static func render(_ data: Data, verbose: Bool = false) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["device"] is [String: Any] else {
            throw NSError(domain: "DiagnosticInterleave", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a combined phone/device diagnostics export."])
        }
        let device = dictionary(root["device"]), metadata = dictionary(device["metadata"]), metrics = dictionary(device["metrics"])
        let events = normalizedEvents(root)
        let fullDate = DateFormatter(); fullDate.locale = Locale(identifier: "en_US_POSIX")
        fullDate.timeZone = TimeZone(secondsFromGMT: 0); fullDate.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let time = DateFormatter(); time.locale = fullDate.locale; time.timeZone = fullDate.timeZone; time.dateFormat = "HH:mm:ss.SSS"
        func stamp(_ unix: Int64?, full: Bool = false) -> String {
            guard let unix else { return "UNSYNCED" }
            return (full ? fullDate : time).string(from: Date(timeIntervalSince1970: Double(unix)/1000))
        }
        func metric(_ key: String) -> String { number(metrics[key]).map(String.init) ?? "unavailable" }
        var out = ["TRANSIT TRACKER DIAGNOSTICS", "", "Collected: \(stamp(number(root["collectedAtUnixMs"]), full: true)) UTC",
            "Firmware: \(metadata["firmwareBuild"] as? String ?? "unknown")",
            "App: \(root["phoneAppVersion"] as? String ?? "unknown") (\(root["phoneAppBuild"] as? String ?? "unknown"))",
            "Device: \(metadata["deviceModel"] as? String ?? "unknown")", "Boot ID: \(number(metadata["bootId"]).map(String.init) ?? "unknown")",
            "Mode: \(verbose ? "VERBOSE — every retained event" : "NORMAL — cleaned timeline")", "",
            "SUMMARY", "Boots                  \(metric("bootCount"))", "Boot successes         \(metric("bootDataSuccessCount"))",
            "Boot failures          \(metric("bootDataFailureCount"))", "Fetches succeeded/all  \(metric("fetchSuccesses")) / \(metric("fetchAttempts"))",
            "BLE timeouts           \(metric("bleTimeoutCount"))", "Startup timeouts       \(metric("startupTimeoutCount"))",
            "Unexpected resets      \(metric("unexpectedResetCount"))", "", "STARTUP LATENCY",
            "<2s                    \(metric("latencyUnder2s"))", "2–4s                   \(metric("latency2To4s"))",
            "4–8s                   \(metric("latency4To8s"))", "8–15s                  \(metric("latency8To15s"))",
            ">15s                   \(metric("latencyOver15s"))", "", "RECENT PROBLEMS"]
        let problems = events.filter { $0.level == "WARN" || $0.level == "ERROR" || $0.code.contains("TIMEOUT") || $0.code.contains("FAILURE") || $0.code.contains("FAILED") || $0.code == "UNEXPECTED_RESET" }
        if problems.isEmpty { out.append("No problem events remain in the retained buffers.") }
        for event in problems {
            out.append("\(stamp(event.unix, full: true)) \(event.source) \(event.code) boot=\(event.boot ?? "unknown") session=\(event.session)\(event.context.isEmpty ? "" : " state="+event.context) value1=\(event.value1) value2=\(event.value2)")
        }
        for (key, code) in [("unexpectedResetCount", "UNEXPECTED_RESET"), ("startupTimeoutCount", "STARTUP_TIMEOUT"), ("fetchFailures", "FETCH_FAILURE"), ("bootDataFailureCount", "STARTUP_TIMEOUT")] {
            if let count = number(metrics[key]), count > 0, !events.contains(where: { $0.code == code }) {
                out.append("\(key): \(count). No matching event remains in retained logs; historical times/boot IDs are unknown.")
            }
        }
        let transactionLines = transactions(events, stamp: { stamp($0, full: true) })
        out += ["", "PAYLOAD DELIVERY TRANSACTIONS"] + payloadTransactions(events, collected: number(root["collectedAtUnixMs"]))
        out += ["", "STARTUP / WAKE TRANSACTIONS"] + transactionLines
        out += ["", "FULL INTERLEAVE (UTC)", "Device durations use monotonic uptime. Cross-device gaps are approximate; no cause is inferred.",
                "UNSYNCED rows have no usable clock anchor and appear separately at the end."]
        let lines = verbose ? events.map { Line(event: $0, code: $0.code, references: [$0.id], firstUptime: $0.uptime) } : cleaned(events)
        let eventsById = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        var lastGroup = "", previous: Event?
        for line in lines {
            let event = line.event
            let group = "BOOT \(event.boot ?? "unknown") — Session \(event.session)" + (event.transaction.map { " — Transaction "+$0 } ?? "")
            if group != lastGroup { out += ["", "──────── \(group) ────────"]; lastGroup = group }
            if let previous, let prior = previous.unix, let current = event.unix,
               current-prior > 500, (previous.session == event.session && event.session != "unassigned" || previous.boot != nil && previous.boot == event.boot) {
                let spanStart = line.references.compactMap { eventsById[$0]?.unix }.min() ?? current
                let gap = verbose ? current-prior : max(0, min(current, spanStart)-prior)
                let severity = gap > 5000 ? "SEVERE" : gap > 2000 ? "SUSPICIOUS" : "NOTEWORTHY"
                if gap > 500 {
                    out.append("    ⚠ \(String(format: "%.3f", Double(gap)/1000))s GAP — \(severity) (outside known collapsed spans)")
                }
            }
            var detail = line.detail
            if let bytes = event.bytes { detail += " bytes=\(bytes)" }
            if let chunk = event.chunk { detail += " chunk=\(chunk)" }
            if let chunks = event.chunks { detail += " chunks=\(chunks)" }
            if let mode = event.writeMode { detail += " writeMode=\(mode)" }
            if let duration = event.duration, !detail.contains("duration=") { detail += " duration=\(duration)ms" }
            if let error = event.errorCode { detail += " context=\(error)" }
            if event.code == "PAYLOAD_PARSE_FAILURE", event.source == "DEVICE" {
                let errors: [Int64: String] = [1:"INVALID_TRANSIT_PAYLOAD",2:"UNAVAILABLE",3:"FRAME_LENGTH_MISMATCH",4:"CHECKSUM_MISMATCH",5:"STALE_TRANSACTION",6:"PAUSED",7:"INTERRUPTED"]
                detail += " error=" + (errors[event.value1] ?? "UNKNOWN")
            }
            if verbose {
                detail += " level=\(event.level) value1=\(event.value1) value2=\(event.value2)"
            } else {
                if event.level == "WARN" || event.level == "ERROR" { detail += " [\(event.level)]" }
                if event.code == "BLE_DISCONNECTED" { detail += " reason=\(event.value1)" }
                else if event.important && event.value1 != 0 && event.context.isEmpty { detail += " value1=\(event.value1)" }
                if event.important && event.value2 != 0 { detail += " value2=\(event.value2)" }
            }
            if !event.context.isEmpty { detail += " state=\(event.context)" }
            if verbose { detail += " #\(event.sequence) uptime=\(event.uptime)ms timestampSource=\(event.timestampSource)" }
            out.append("\(stamp(event.unix))  \(event.source.padding(toLength: 6, withPad: " ", startingAt: 0))  \(line.code) \(detail)")
            if line.missing { out.append("                    ↳ NO COMPLETION EVENT (or ambiguous overlapping operations)") }
            previous = event
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func payloadTransactions(_ events: [Event], collected: Int64?) -> [String] {
        let ids = Set(events.compactMap(\.transaction))
        guard !ids.isEmpty else { return ["No transaction IDs in this export (legacy firmware/app or no retained requests)."] }
        let groups = ids.map { id in (id, events.filter { $0.transaction == id }) }.sorted {
            let a = $0.1.compactMap(\.unix).min() ?? .max, b = $1.1.compactMap(\.unix).min() ?? .max
            return a == b ? $0.0 < $1.0 : a < b
        }
        var output: [String] = []
        let stages = Set(["DATA_REQUEST_SENT", "DEVICE_DATA_REQUEST_RECEIVED", "DATA_REQUEST_COALESCED", "FETCH_STARTED", "FETCH_SUCCESS", "FETCH_FAILURE",
            "BLE_RESPONSE_BEGIN", "BLE_RESPONSE_QUEUED", "BLE_RESPONSE_WRITE_CONFIRMED", "BLE_RESPONSE_WRITE_FAILED",
            "RESPONSE_RX_STARTED", "RESPONSE_RX_COMPLETE", "RESPONSE_RX_FAILED", "PAYLOAD_PARSE_STARTED", "PAYLOAD_PARSE_SUCCESS", "PAYLOAD_PARSE_FAILURE",
            "DATA_APPLIED", "DATA_APPLIED_ACK_RECEIVED", "DATA_APPLIED_ACK_REJECTED", "DATA_APPLIED_ACK_TIMEOUT", "DISPLAY_UPDATED"])
        for (id, trace) in groups {
            func has(_ code: String) -> Bool { trace.contains { $0.code == code } }
            let start = trace.first { $0.code == "DATA_REQUEST_SENT" } ?? trace.first!
            let latest = trace.compactMap(\.unix).max()
            let settled = has("DATA_APPLIED_ACK_TIMEOUT") || has("DATA_REQUEST_TIMEOUT") || has("BLE_RESPONSE_WRITE_FAILED") ||
                (collected != nil && latest != nil && collected!-latest! >= 1500)
            let outcome: String
            if has("DATA_REQUEST_COALESCED") && !has("FETCH_STARTED") {
                outcome = "COALESCED REQUEST — see linked request in context; no independent response expected"
            } else if has("PAYLOAD_PARSE_FAILURE") { outcome = "DEVICE PAYLOAD PARSE FAILURE" }
            else if has("BLE_RESPONSE_WRITE_FAILED") { outcome = "PHONE / COREBLUETOOTH TRANSMISSION FAILURE" }
            else if has("DATA_APPLIED") && has("DATA_APPLIED_ACK_RECEIVED") && has("DISPLAY_UPDATED") { outcome = "SUCCESS" }
            else if has("DATA_APPLIED") && has("DATA_APPLIED_ACK_RECEIVED") && !has("DISPLAY_UPDATED") && settled { outcome = "DISPLAY / RENDER FAILURE" }
            else if has("PAYLOAD_PARSE_SUCCESS") && !has("DATA_APPLIED") && settled { outcome = "DEVICE APPLICATION STATE FAILURE" }
            else if has("RESPONSE_RX_STARTED") && !has("RESPONSE_RX_COMPLETE") && (has("DATA_APPLIED_ACK_TIMEOUT") || has("RESPONSE_RX_FAILED")) { outcome = "BLE FRAME / CHUNK DELIVERY FAILURE" }
            else if has("BLE_RESPONSE_QUEUED") && !has("RESPONSE_RX_STARTED") && has("DATA_APPLIED_ACK_TIMEOUT") { outcome = "BLE DELIVERY / DEVICE RX START FAILURE" }
            else if has("FETCH_SUCCESS") && !has("BLE_RESPONSE_BEGIN") && settled { outcome = "PHONE RESPONSE PIPELINE FAILURE" }
            else if has("DATA_APPLIED") && has("DATA_APPLIED_ACK_TIMEOUT") { outcome = "DEVICE APPLIED; ACK DELIVERY NOT CONFIRMED" }
            else if has("FETCH_FAILURE") { outcome = "FETCH_FAILURE (before delivery)" }
            else if has("DATA_APPLIED_ACK_REJECTED") { outcome = "DEVICE RESPONSE / ACK REJECTED" }
            else { outcome = "INCOMPLETE / IN PROGRESS" }
            let end = trace.last { $0.code == "DISPLAY_UPDATED" } ?? trace.last { $0.code == "DATA_APPLIED_ACK_RECEIVED" } ?? trace.last!
            let duration = start.source == end.source ? end.uptime-start.uptime : (start.unix != nil && end.unix != nil ? end.unix!-start.unix! : nil)
            output.append("TRANSACTION \(id) — \(outcome)" + (duration.map { " — ≈"+String(format: "%.3fs",Double($0)/1000) } ?? ""))
            output.append("  Classification describes retained stage evidence, not a hardware root cause. Missing stages can also reflect unavailable logs.")
            for event in trace where stages.contains(event.code) || event.level == "WARN" || event.level == "ERROR" {
                let relative = event.source == start.source ? event.uptime-start.uptime : (event.unix != nil && start.unix != nil ? event.unix!-start.unix! : nil)
                let delta = relative.map { String(format: "%+.3fs",Double($0)/1000) } ?? "time unknown"
                output.append("  \(delta) \(event.source) \(event.code)" + (event.bytes.map { " bytes=\($0)" } ?? "") + (event.errorCode.map { " context=\($0)" } ?? ""))
            }
        }
        return output
    }

    private static func transactions(_ events: [Event], stamp: (Int64?) -> String) -> [String] {
        let device = events.filter { $0.source == "DEVICE" }.sorted { $0.sequence < $1.sequence }
        var starts: [(Event, Bool)] = []
        var standby = false, waitingForWakeBLE = false
        for event in device {
            if event.code == "BOOT_START" { starts.append((event, false)) }
            if event.code == "POWER_STANDBY" { standby = true }
            if event.code == "POWER_ACTIVE", standby { waitingForWakeBLE = true; standby = false }
            if event.code == "BLE_INIT_START", waitingForWakeBLE { starts.append((event, true)); waitingForWakeBLE = false }
        }
        guard !starts.isEmpty else { return ["INCOMPLETE — no retained BOOT_START or explicit wake/BLE activation boundary."] }
        var output: [String] = []
        let milestones = Set(["BOOT_START", "BLE_INIT_START", "BLE_CONNECTED", "DEVICE_DATA_REQUEST_RECEIVED", "FETCH_STARTED", "FETCH_SUCCESS", "PAYLOAD_RX_COMPLETE", "STARTUP_COMPLETE", "STARTUP_TIMEOUT"])
        for (index, item) in starts.enumerated() {
            let (start, wake) = item
            let endSequence = index+1 < starts.count ? starts[index+1].0.sequence : Int64.max
            let scope = device.filter { $0.sequence >= start.sequence && $0.sequence < endSequence }
            let fresh = scope.first { $0.code == "FETCH_SUCCESS" }
            let success = scope.first { $0.code == "STARTUP_COMPLETE" || (wake && $0.code == "DISPLAY_UPDATE_COMPLETE" && $0.value1 != 0 && fresh != nil && $0.sequence > fresh!.sequence) }
            let sessions = Set(scope.map(\.session).filter { $0 != "unassigned" })
            let nextStartTime = index+1 < starts.count ? starts[index+1].0.unix : nil
            let failureCodes = Set(["STARTUP_TIMEOUT", "DATA_REQUEST_TIMEOUT", "FETCH_FAILURE", "BLE_TIMEOUT", "BLE_DISCONNECTED", "BLE_CONNECT_FAILED"])
            let phoneFailures = events.filter { event in
                event.source == "PHONE" && failureCodes.contains(event.code) && sessions.contains(event.session) &&
                event.unix != nil && start.unix != nil && event.unix! >= start.unix! &&
                (nextStartTime == nil || event.unix! < nextStartTime!) &&
                (success?.unix == nil || event.unix! <= success!.unix!)
            }
            let deviceFailure = scope.first {
                failureCodes.contains($0.code) && (success == nil || $0.sequence < success!.sequence)
            }
            let failure = ([deviceFailure].compactMap { $0 } + phoneFailures).sorted {
                if let a = $0.unix, let b = $1.unix { return a == b ? $0.id < $1.id : a < b }
                return $0.source == "DEVICE" && $1.source != "DEVICE"
            }.first
            let terminal = success ?? failure
            let outcome = success != nil ? "SUCCESS" : failure.map { $0.code.contains("TIMEOUT") ? "TIMEOUT" : $0.code == "FETCH_FAILURE" ? "FETCH_FAILURE" : "BLE_FAILURE" } ?? "INCOMPLETE"
            let elapsed: Int64? = terminal.flatMap {
                if $0.source == "DEVICE" { return $0.uptime-start.uptime }
                guard let end = $0.unix, let begin = start.unix else { return nil }
                return end-begin
            }
            let duration = elapsed.map { (terminal?.source == "PHONE" ? "≈" : "") + String(format: "%.3fs", Double($0)/1000) } ?? "duration unknown"
            output.append("\(wake ? "WAKE" : "BOOT") \(start.boot ?? "unknown") — \(outcome) — \(duration) — \(stamp(start.unix))")
            if success != nil && failure != nil { output.append("  Recovery followed a retained failure/timeout; see problems above.") }
            var previousTime = start.unix
            for event in events where milestones.contains(event.code) {
                let belongs: Bool
                if event.source == "DEVICE" {
                    belongs = event.sequence >= start.sequence && event.sequence < endSequence &&
                        (terminal == nil || (terminal!.source == "DEVICE" ? event.sequence <= terminal!.sequence :
                            event.unix != nil && terminal!.unix != nil && event.unix! <= terminal!.unix!))
                } else {
                    belongs = sessions.contains(event.session) && event.unix != nil && start.unix != nil && event.unix! >= start.unix! &&
                        (nextStartTime == nil || event.unix! < nextStartTime!) &&
                        (terminal?.unix == nil || event.unix! <= terminal!.unix!)
                }
                guard belongs else { continue }
                let relative = event.source == "DEVICE" ? event.uptime-start.uptime : event.unix!-start.unix!
                let gap = event.unix.flatMap { t in previousTime.map { t-$0 } }
                output.append("  \(String(format: "%+.3f", Double(relative)/1000))s \(event.source) \(event.code)\(gap.map { "  Δ≈\($0)ms" } ?? "")")
                previousTime = event.unix
            }
        }
        return output
    }
}
