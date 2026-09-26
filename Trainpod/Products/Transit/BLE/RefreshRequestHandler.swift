import Combine
import Foundation
import UIKit

/// Owned alongside the production bridge, not by a foreground-only view callback.
@MainActor
final class RefreshRequestHandler: ObservableObject {
    @Published private(set) var requestCount = UserDefaults.standard.integer(forKey: "backgroundRefreshRequestCount")
    @Published private(set) var lastRequest = UserDefaults.standard.object(forKey: "lastBackgroundRefreshRequest") as? Date
    @Published private(set) var lastRequestWasBackgrounded = UserDefaults.standard.bool(forKey: "lastRefreshRequestWasBackgrounded")
    @Published private(set) var status = "Waiting for the device to request data."
    @Published private(set) var lastFailure: String?
    private let bluetooth: BluetoothService
    private let bridge: MessageBridge
    private let provider: any TransitPayloadProvider
    private let defaults: UserDefaults
    private let appliedACK = DeliveryAcknowledgements()
    private var pendingTransaction: PayloadTransaction?
    private var activeTransaction: PayloadTransaction?
    // Connection-scoped IDs cannot collide between different peripherals.
    private enum StationRequestState {
        case inFlight
        case completed(Data)
    }
    private var stationRequests: [PayloadTransaction: StationRequestState] = [:]
    private var completedOrder: [PayloadTransaction] = []
    private var connectionGeneration: UInt64 = 0
    private var activeGeneration: UInt64 = 0
    private var activeOperation: UUID?
    private var pending = false
    private var sendingPayload = false
    private var sendTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(bluetooth: BluetoothService, bridge: MessageBridge, provider: any TransitPayloadProvider, defaults: UserDefaults = .standard) {
        self.bluetooth = bluetooth
        self.bridge = bridge
        self.defaults = defaults
        self.provider = provider
        lastFailure = defaults.string(forKey: "lastLiveTransitError")
        requestCount = defaults.integer(forKey: "backgroundRefreshRequestCount")
        lastRequest = defaults.object(forKey: "lastBackgroundRefreshRequest") as? Date
        lastRequestWasBackgrounded = defaults.bool(forKey: "lastRefreshRequestWasBackgrounded")
        bluetooth.controlMessageHandler = { [weak self] timestamp, backgrounded, transaction in
            self?.receiveRequest(at: timestamp, backgrounded: backgrounded, transaction: transaction)
        }
        bluetooth.dataAppliedHandler = { [weak self] transaction, status, bytes in
            guard let self else { return }
            self.appliedACK.receive(transaction, status: status, bytes: bytes, session: self.bluetooth.diagnosticSessionId)
        }
        appliedACK.statusHandler = { [weak self] transaction, message in
            if self?.activeTransaction == transaction { self?.status = message }
        }
        // A notification can arrive just before the subscription-ready callback.
        bluetooth.readyHandler = { [weak self] in self?.sendIfReady() }
        bridge.transitSendReadyHandler = { [weak self] in self?.sendIfReady() }
        bluetooth.connectionEndedHandler = { [weak self] in
            guard let self else { return }
            self.connectionGeneration &+= 1
            self.pending = false
            self.pendingTransaction = nil
            self.stationRequests.removeAll()
            self.completedOrder.removeAll()
            self.sendTask?.cancel()
            self.deadlineTask?.cancel()
            self.endBackgroundTask()
        }
    }

    deinit { sendTask?.cancel(); deadlineTask?.cancel() }

    private func receiveRequest(at timestamp: Date, backgrounded: Bool, transaction: PayloadTransaction?) {
        if let transaction { PhoneDiagnosticLog.shared.retainTransaction(transaction.id, sessionId: bluetooth.diagnosticSessionId) }
        PhoneDiagnosticLog.shared.record("DEVICE_DATA_REQUEST_RECEIVED", sessionId: bluetooth.diagnosticSessionId, transactionId: transaction?.id)
        guard !bluetooth.diagnosticsInProgress else { return }
        requestCount = defaults.integer(forKey: "backgroundRefreshRequestCount") + 1
        lastRequest = timestamp
        lastRequestWasBackgrounded = backgrounded
        defaults.set(requestCount, forKey: "backgroundRefreshRequestCount")
        defaults.set(timestamp, forKey: "lastBackgroundRefreshRequest")
        defaults.set(backgrounded, forKey: "lastRefreshRequestWasBackgrounded")
        if let transaction {
            FileLogger.shared.log("[BLE-REQ] Received STATIONS request id=\(transaction.id)")
            if case .inFlight? = stationRequests[transaction] {
                FileLogger.shared.log("[BLE-REQ] Duplicate request id=\(transaction.id) already in flight")
                sendIfReady()
                return
            }
            if case .completed? = stationRequests[transaction] {
                FileLogger.shared.log("[BLE-REQ] Duplicate completed request id=\(transaction.id); resending stored response")
            }
        }
        FileLogger.shared.log("[REFRESH] NEED_DATA received backgrounded=\(backgrounded)")

        if sendTask != nil && activeGeneration != connectionGeneration {
            // Queue new connection demand while the cancelled old waiter drains.
            // The old task's defer starts this request without a second resolver.
            if !pending {
                pendingTransaction = transaction
                if let transaction, stationRequests[transaction] == nil {
                    stationRequests[transaction] = .inFlight
                }
                pending = true
            }
            FileLogger.shared.log("[BLE-REQ] New connection request queued while previous work finishes")
            return
        }
        guard sendTask == nil else {
            PhoneDiagnosticLog.shared.record("DATA_REQUEST_COALESCED", transactionId: transaction?.id, errorCode: activeTransaction?.id)
            FileLogger.shared.log("[REFRESH] Context/API refresh already in progress; coalescing request")
            return
        }
        // Every demand rechecks readiness, even if an earlier request arrived before
        // characteristic setup. Recovery must not depend on a ready callback firing.
        status = "NEED_DATA received; checking transit cache"
        if !pending {
            pendingTransaction = transaction
            if let transaction, stationRequests[transaction] == nil {
                stationRequests[transaction] = .inFlight
            }
        }
        else if pendingTransaction != transaction { PhoneDiagnosticLog.shared.record("DATA_REQUEST_COALESCED", transactionId: transaction?.id, errorCode: pendingTransaction?.id) }
        pending = true
        if bridge.isSending { FileLogger.shared.log("[REFRESH] Request queued until current BLE write finishes") }
        sendIfReady()
    }

    private func sendIfReady() {
        guard pending, bridge.canSend, !bridge.isSending, sendTask == nil else { return }
        pending = false
        let transaction = pendingTransaction
        activeTransaction = transaction
        pendingTransaction = nil
        let operation = UUID()
        let generation = connectionGeneration
        activeOperation = operation
        activeGeneration = connectionGeneration
        FileLogger.shared.log("[REFRESH] Device refresh started")
        status = "Checking current context and transit cache"
        print("[E2E] fetching live transit payload")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Device live transit refresh") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activeOperation == operation,
                      self.connectionGeneration == generation else { return }
                // End synchronously; cancellation need not finish shared provider work.
                self.endBackgroundTask()
                self.sendTask?.cancel()
                self.deadlineTask?.cancel()
                self.recordFailure("Background execution expired before the request finished.")
                FileLogger.shared.log("[REFRESH] Background execution time expired")
            }
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.activeOperation == operation,
                  self.connectionGeneration == generation else { return }
            self.endBackgroundTask()
            self.sendTask?.cancel()
            self.recordFailure("Station request exceeded its 25-second deadline.")
            FileLogger.shared.log("[REFRESH] Refresh deadline exceeded")
        }
        let refreshStarted = Date()
        let diagnosticSession = bluetooth.diagnosticSessionId
        let storedResponse: Data?
        if let transaction, case .completed(let payload)? = stationRequests[transaction] {
            storedResponse = payload
        } else {
            storedResponse = nil
        }
        sendTask = Task { [weak self] in
            guard let self else { return }
            await PhoneDiagnosticContext.$sessionId.withValue(diagnosticSession) {
            await PhoneDiagnosticContext.$transactionId.withValue(transaction?.id) {
            defer {
                // Failed/cancelled resolution is retryable, never a completed payload.
                // Keep IN_FLIGHT until all work (including the error write) has drained.
                if generation == self.connectionGeneration, let transaction,
                   case .inFlight? = self.stationRequests[transaction] {
                    self.stationRequests.removeValue(forKey: transaction)
                }
                self.activeOperation = nil
                self.sendTask = nil
                self.sendingPayload = false
                self.deadlineTask?.cancel()
                self.deadlineTask = nil
                self.endBackgroundTask()
                // New connection demand can wait while cancelled work unwinds.
                self.sendIfReady()
            }
            var fetched = false
            do {
                let payload: Data
                if let storedResponse {
                    payload = storedResponse
                } else {
                    PhoneDiagnosticLog.shared.record("FETCH_STARTED", sessionId: diagnosticSession)
                    payload = try await self.provider.currentPayload()
                    PhoneDiagnosticLog.shared.record("FETCH_SUCCESS", sessionId: diagnosticSession, value1: Int64(payload.count))
                }
                try Task.checkCancellation()
                guard generation == self.connectionGeneration else { throw CancellationError() }
                guard payload != TransitMessage.unavailablePayload else { throw LiveTransitError.noDirections }
                if let transaction {
                    // Retain exact bytes before transmission, including failed writes.
                    self.rememberResponse(payload, for: transaction)
                }
                fetched = true
                FileLogger.shared.log("[REFRESH] Data received bytes=\(payload.count) resolveMs=\(Int(Date().timeIntervalSince(refreshStarted) * 1000))")
                try Task.checkCancellation()
                guard !self.bridge.isSending else {
                    // Keep the already-fetched bytes in stationRequests and resume
                    // on transport readiness, rather than waiting five seconds.
                    self.pendingTransaction = transaction
                    self.pending = true
                    FileLogger.shared.log("[REFRESH] Response queued until current BLE write finishes")
                    return
                }
                self.status = "Sending live transit payload"
                self.sendingPayload = true
                FileLogger.shared.log("[REFRESH] Sending payload to tracker")
                let platformCount = String(decoding: payload, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("P\t") }.count
                FileLogger.shared.log("[BLE] Sending platformCount=\(platformCount)")
                if let transaction { self.appliedACK.begin(transaction, bytes: payload.count, session: diagnosticSession) }
                try await self.bridge.send(payload, mode: .withResponse, transaction: transaction)
                if let transaction { self.appliedACK.transmissionCompleted(transaction) }
                FileLogger.shared.log("[REFRESH] CoreBluetooth write completed; device ACK tracked separately")
                if transaction == nil { self.status = "Legacy BLE write completed; no device applied ACK supported." }
                self.defaults.set(Date(), forKey: "lastLiveTransitSent")
                print("[E2E] live transit write completed")
            } catch {
                // An old connection must not overwrite the new connection's status/state.
                guard generation == self.connectionGeneration else { return }
                if let transaction { self.appliedACK.cancel(transaction) }
                let nsError = error as NSError
                let failure = "Station request \(transaction?.id ?? "legacy") failed: \(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
                FileLogger.shared.log("[BLE-REQ] " + failure)
                if !Task.isCancelled { self.recordFailure(failure) }
                PhoneDiagnosticLog.shared.record(fetched ? "BLE_RESPONSE_SEND_FAILED" : "FETCH_FAILURE", sessionId: diagnosticSession, level: "ERROR", value1: Int64((error as NSError).code))
                FileLogger.shared.log("[REFRESH] Device refresh failed code=\((error as NSError).code) cancelled=\(Task.isCancelled)")
                // Failure is not fresh data. Device retains its board and keeps retrying.
                // Never send into a new connection from an obsolete cancelled request.
                if !fetched, !Task.isCancelled, generation == self.connectionGeneration, self.bridge.canSend, !self.bridge.isSending {
                    do {
                        self.sendingPayload = true
                        try await self.bridge.send(TransitMessage.unavailablePayload, mode: .withResponse, transaction: transaction)
                        FileLogger.shared.log("[REFRESH] Unavailable response sent; device will retry")
                    } catch {
                        FileLogger.shared.log("[REFRESH] Unavailable response failed code=\((error as NSError).code)")
                    }
                }
                print("[E2E] \(self.status)")
            }
            }
            }
        }
    }

    private func rememberResponse(_ payload: Data, for transaction: PayloadTransaction) {
        stationRequests[transaction] = .completed(payload)
        completedOrder.removeAll { $0 == transaction }
        completedOrder.append(transaction)
        // Retain recent responses for retries, bounded independently of uptime.
        while completedOrder.count > 8 {
            stationRequests.removeValue(forKey: completedOrder.removeFirst())
        }
    }

    private func recordFailure(_ message: String) {
        status = message
        lastFailure = message
        defaults.set(message, forKey: "lastLiveTransitError")
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            let task = backgroundTask
            backgroundTask = .invalid
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
