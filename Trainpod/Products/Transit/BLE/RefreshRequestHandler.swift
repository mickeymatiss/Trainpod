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
    private let bluetooth: BluetoothService
    private let bridge: MessageBridge
    private let provider: any TransitPayloadProvider
    private let defaults: UserDefaults
    private let appliedACK = DeliveryAcknowledgements()
    private var pendingTransaction: PayloadTransaction?
    private var activeTransaction: PayloadTransaction?
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
        bluetooth.connectionEndedHandler = { [weak self] in
            self?.pending = false
            self?.sendTask?.cancel()
        }
    }

    deinit { sendTask?.cancel(); deadlineTask?.cancel() }

    private func receiveRequest(at timestamp: Date, backgrounded: Bool, transaction: PayloadTransaction?) {
        if let transaction { PhoneDiagnosticLog.shared.retainTransaction(transaction.id) }
        PhoneDiagnosticLog.shared.record("DEVICE_DATA_REQUEST_RECEIVED", sessionId: bluetooth.diagnosticSessionId, transactionId: transaction?.id)
        guard !bluetooth.diagnosticsInProgress else { return }
        FileLogger.shared.log("[REFRESH] NEED_DATA received backgrounded=\(backgrounded)")
        requestCount = defaults.integer(forKey: "backgroundRefreshRequestCount") + 1
        lastRequest = timestamp
        lastRequestWasBackgrounded = backgrounded
        defaults.set(requestCount, forKey: "backgroundRefreshRequestCount")
        defaults.set(timestamp, forKey: "lastBackgroundRefreshRequest")
        defaults.set(backgrounded, forKey: "lastRefreshRequestWasBackgrounded")
        if sendingPayload || bridge.isSending {
            PhoneDiagnosticLog.shared.record("DATA_REQUEST_COALESCED", transactionId: transaction?.id, errorCode: activeTransaction?.id)
            FileLogger.shared.log("[REFRESH] BLE payload send already in progress; coalescing request")
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
        if !pending { pendingTransaction = transaction }
        else if pendingTransaction != transaction { PhoneDiagnosticLog.shared.record("DATA_REQUEST_COALESCED", transactionId: transaction?.id, errorCode: pendingTransaction?.id) }
        pending = true
        sendIfReady()
    }

    private func sendIfReady() {
        guard pending, bridge.canSend, !bridge.isSending, sendTask == nil else { return }
        pending = false
        let transaction = pendingTransaction
        activeTransaction = transaction
        pendingTransaction = nil
        FileLogger.shared.log("[REFRESH] Device refresh started")
        status = "Checking current context and transit cache"
        print("[E2E] fetching live transit payload")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Device live transit refresh") { [weak self] in
            MainActor.assumeIsolated {
                FileLogger.shared.log("[REFRESH] Background execution time expired")
                self?.sendTask?.cancel()
                self?.endBackgroundTask()
            }
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            FileLogger.shared.log("[REFRESH] Refresh deadline exceeded")
            self?.sendTask?.cancel()
        }
        let diagnosticSession = bluetooth.diagnosticSessionId
        sendTask = Task { [weak self] in
            guard let self else { return }
            await PhoneDiagnosticContext.$transactionId.withValue(transaction?.id) {
            defer {
                self.sendTask = nil
                self.sendingPayload = false
                self.deadlineTask?.cancel()
                self.deadlineTask = nil
                self.endBackgroundTask()
            }
            var fetched = false
            PhoneDiagnosticLog.shared.record("FETCH_STARTED", sessionId: diagnosticSession)
            do {
                let payload = try await self.provider.currentPayload()
                fetched = true
                PhoneDiagnosticLog.shared.record("FETCH_SUCCESS", sessionId: diagnosticSession, value1: Int64(payload.count))
                FileLogger.shared.log("[REFRESH] Data received bytes=\(payload.count)")
                try Task.checkCancellation()
                guard !self.bridge.isSending else {
                    FileLogger.shared.log("[REFRESH] Another BLE send is active; next NEED_DATA will retry")
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
                if let transaction { self.appliedACK.cancel(transaction) }
                PhoneDiagnosticLog.shared.record(fetched ? "BLE_RESPONSE_SEND_FAILED" : "FETCH_FAILURE", sessionId: diagnosticSession, level: "ERROR", value1: Int64((error as NSError).code))
                FileLogger.shared.log("[REFRESH] Device refresh failed code=\((error as NSError).code) cancelled=\(Task.isCancelled)")
                // Failure is not fresh data. Device retains its board and keeps retrying.
                // Never send into a new connection from an obsolete cancelled request.
                if !Task.isCancelled, self.bridge.canSend, !self.bridge.isSending {
                    do {
                        self.sendingPayload = true
                        try await self.bridge.send(TransitMessage.unavailablePayload, mode: .withResponse, transaction: transaction)
                        FileLogger.shared.log("[REFRESH] Unavailable response sent; device will retry")
                    } catch {
                        FileLogger.shared.log("[REFRESH] Unavailable response failed code=\((error as NSError).code)")
                    }
                }
                self.status = error is CancellationError ? "Live refresh cancelled or timed out" : "Live refresh failed: \(error.localizedDescription)"
                self.defaults.set(self.status, forKey: "lastLiveTransitError")
                print("[E2E] \(self.status)")
            }
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
