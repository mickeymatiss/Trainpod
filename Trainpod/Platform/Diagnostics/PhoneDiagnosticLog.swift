import Foundation

nonisolated struct PhoneDiagnosticEvent: Codable {
    let sequence: UInt64
    let unixTimeMs: Int64
    let uptimeMs: UInt64
    let sessionId: String
    let eventCode: String
    let level: String
    let value1: Int64
    let value2: Int64
    let transactionId: String?
    let chunk: Int?
    let chunks: Int?
    let bytes: Int?
    let writeMode: String?
    let durationMs: Int64?
    let errorCode: String?
}

/// Bounded structured history. No payloads, coordinates, secrets, or hardware identifiers.
nonisolated final class PhoneDiagnosticLog: @unchecked Sendable {
    static let shared = PhoneDiagnosticLog()
    let processId = UUID().uuidString
    private let lock = NSLock()
    private var entries: [PhoneDiagnosticEvent] = []
    private struct TransactionKey: Hashable {
        let session: String
        let transaction: String
        init?(session: String, transaction: String) {
            let session = session.lowercased()
            guard !session.isEmpty, session != "00000000" else { return nil }
            self.session = session
            self.transaction = transaction
        }
    }
    private var transactionOrder: [TransactionKey] = []
    private var transactionEvents: [TransactionKey: [PhoneDiagnosticEvent]] = [:]
    private var sequence: UInt64 = 0
    private var session = ""
    var currentSessionId: String {
        if let scoped = PhoneDiagnosticContext.sessionId { return scoped }
        lock.lock(); defer { lock.unlock() }; return session
    }
    func setSession(_ id: String) { lock.lock(); session = id; lock.unlock() }
    func retainTransaction(_ id: String, sessionId: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let key = TransactionKey(session: sessionId ?? PhoneDiagnosticContext.sessionId ?? session, transaction: id),
              !transactionOrder.contains(key) else { return }
        transactionOrder.append(key); transactionEvents[key] = []
        while transactionOrder.count > 5 { transactionEvents.removeValue(forKey: transactionOrder.removeFirst()) }
    }
    func record(_ code: String, sessionId: String? = nil, level: String = "INFO", value1: Int64 = 0, value2: Int64 = 0, transactionId: String? = nil, chunk: Int? = nil, chunks: Int? = nil, bytes: Int? = nil, writeMode: String? = nil, durationMs: Int64? = nil, errorCode: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        let tx = transactionId ?? PhoneDiagnosticContext.transactionId
        let event = PhoneDiagnosticEvent(sequence: sequence,
            unixTimeMs: Int64(Date().timeIntervalSince1970 * 1000),
            uptimeMs: UInt64(ProcessInfo.processInfo.systemUptime * 1000),
            sessionId: sessionId ?? PhoneDiagnosticContext.sessionId ?? session, eventCode: code, level: level, value1: value1, value2: value2, transactionId: tx, chunk: chunk, chunks: chunks, bytes: bytes,
            writeMode: writeMode, durationMs: durationMs, errorCode: errorCode)
        entries.append(event)
        if let tx, let key = TransactionKey(session: event.sessionId, transaction: tx),
           transactionEvents[key] != nil, !code.contains("CHUNK") {
            transactionEvents[key]!.append(event)
            if transactionEvents[key]!.count > 64 { transactionEvents[key]!.remove(at: 1) }
        }
        if entries.count > 512 { entries.removeFirst(entries.count - 512) }
    }
    func snapshot() -> [PhoneDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        var bySequence = Dictionary(uniqueKeysWithValues: entries.map { ($0.sequence, $0) })
        for history in transactionEvents.values { for event in history { bySequence[event.sequence] = event } }
        return bySequence.values.sorted { $0.sequence < $1.sequence }
    }
}
