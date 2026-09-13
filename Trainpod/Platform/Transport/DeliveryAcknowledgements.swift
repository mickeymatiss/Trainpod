import Foundation

/// Application acknowledgement, deliberately independent from fetch errors and ATT completion.
@MainActor final class DeliveryAcknowledgements {
    private struct Pending {
        let session: String
        let bytes: Int
        var completedAt: TimeInterval?
        var applied = false
        var timedOut = false
        var task: Task<Void, Never>?
    }
    private var pending: [PayloadTransaction: Pending] = [:]
    private var order: [PayloadTransaction] = []
    var statusHandler: ((PayloadTransaction, String) -> Void)?
    func begin(_ tx: PayloadTransaction, bytes: Int, session: String) {
        pending[tx]?.task?.cancel()
        pending[tx] = Pending(session: session, bytes: bytes)
        order.removeAll { $0 == tx }; order.append(tx)
        while order.count > 5 { pending.removeValue(forKey: order.removeFirst())?.task?.cancel() }
    }
    func cancel(_ tx: PayloadTransaction) { pending.removeValue(forKey: tx)?.task?.cancel() }
    func transmissionCompleted(_ tx: PayloadTransaction) {
        guard var entry = pending[tx], !entry.applied else { return }
        entry.completedAt = ProcessInfo.processInfo.systemUptime
        entry.task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, var current = self.pending[tx], !current.applied, let started = current.completedAt else { return }
            current.timedOut = true; current.task = nil; self.pending[tx] = current
            PhoneDiagnosticLog.shared.record("DATA_APPLIED_ACK_TIMEOUT", sessionId: current.session, level: "WARN",
                transactionId: tx.id, bytes: current.bytes, durationMs: Int64((ProcessInfo.processInfo.systemUptime-started)*1000))
            self.statusHandler?(tx, "Device applied ACK timed out (1500 ms). No automatic retry.")
        }
        pending[tx] = entry
        statusHandler?(tx, "BLE write completed; waiting for device applied ACK…")
    }
    func receive(_ tx: PayloadTransaction, status: UInt8, bytes: Int, session: String) {
        guard var entry = pending[tx], entry.session == session else {
            PhoneDiagnosticLog.shared.record("DATA_APPLIED_ACK_UNEXPECTED", sessionId: session, level: "WARN", transactionId: tx.id, bytes: bytes)
            return
        }
        guard !entry.applied else { return } // Duplicate ACK never changes the outcome twice.
        if status != 0 || bytes != entry.bytes {
            entry.task?.cancel(); pending.removeValue(forKey: tx)
            PhoneDiagnosticLog.shared.record("DATA_APPLIED_ACK_REJECTED", sessionId: session, level: "ERROR",
                value1: Int64(status), transactionId: tx.id, bytes: bytes, errorCode: bytes == entry.bytes ? "DEVICE_REJECTED" : "ACK_LENGTH_MISMATCH")
            statusHandler?(tx, "Device rejected the response (status \(status), bytes \(bytes)).")
            return
        }
        entry.task?.cancel(); entry.task = nil; entry.applied = true; pending[tx] = entry
        PhoneDiagnosticLog.shared.record("DATA_APPLIED_ACK_RECEIVED", sessionId: session, transactionId: tx.id, bytes: bytes,
            durationMs: entry.completedAt.map { Int64((ProcessInfo.processInfo.systemUptime-$0)*1000) },
            errorCode: entry.timedOut ? "LATE_ACK" : nil)
        statusHandler?(tx, entry.timedOut ? "Device applied the response; ACK arrived late." : "Device confirmed the response was received, parsed and applied.")
    }
}
