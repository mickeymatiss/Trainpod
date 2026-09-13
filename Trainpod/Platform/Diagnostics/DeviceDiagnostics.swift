import Combine
import Foundation
import UIKit

struct SavedDiagnostic: Identifiable {
    let url: URL
    let date: Date
    var id: String { url.lastPathComponent }
    var readableURL: URL { url.deletingPathExtension().appendingPathExtension("interleaved.txt") }
    var verboseURL: URL { url.deletingPathExtension().appendingPathExtension("verbose.txt") }
}

@MainActor
final class DeviceDiagnostics: ObservableObject {
    @Published private(set) var files: [SavedDiagnostic] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "Wake the device, then download its recent logs and lifetime metrics."
    @Published private(set) var progress: Double = 0
    let bluetooth: BluetoothService
    private let bridge: MessageBridge
    private let directory: URL
    private var assembler = DiagnosticAssembler()
    private var operation: UUID?
    private var requestTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var deadline: TimeInterval = 0
    private var awaitingConfirmation: UInt32?
    private var savedURL: URL?
    private var startedReceiving = false
    private var requestWriteConfirmed = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(bluetooth: BluetoothService, bridge: MessageBridge,
         directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DeviceDiagnostics", isDirectory: true)) {
        self.bluetooth = bluetooth; self.bridge = bridge; self.directory = directory
        bluetooth.diagnosticDataHandler = { [weak self] data in self?.receive(data) }
        reloadFiles()
    }

    func download() {
        guard !busy else { return }
        guard BackgroundReconnectManager.active == nil else { status = DiagnosticError.unavailable.localizedDescription; return }
        PhoneDiagnosticLog.shared.record("DIAGNOSTIC_COLLECTION_STARTED")
        let token = UUID(); operation = token
        busy = true; bluetooth.diagnosticsInProgress = true
        assembler = DiagnosticAssembler(); savedURL = nil; awaitingConfirmation = nil
        startedReceiving = false; requestWriteConfirmed = false; progress = 0
        deadline = ProcessInfo.processInfo.systemUptime + 60
        status = "Waiting for the device. Press its button to wake it if needed."
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Device diagnostics") { [weak self] in
            Task { @MainActor in self?.fail(DiagnosticError.stageTimeout("iOS ended background execution")) }
        }
        // Independent of ATT write continuations: a missing write response cannot hang the UI.
        watchdogTask = Task { [weak self] in
            while let self, self.operation == token {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard self.operation == token else { return }
                if ProcessInfo.processInfo.systemUptime >= self.deadline { self.fail(self.timeoutError()); return }
                if self.startedReceiving && !self.bluetooth.notificationsReady {
                    self.fail(DiagnosticError.disconnected); return
                }
            }
        }
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !self.bluetooth.notificationsReady { self.bluetooth.scanAndConnect() }
                let connectionDeadline = ProcessInfo.processInfo.systemUptime + 60
                while !self.bluetooth.notificationsReady || self.bluetooth.clockSyncInProgress || self.bridge.isSending {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < connectionDeadline else { throw self.timeoutError() }
                    if !self.bluetooth.notificationsReady {
                        self.status = "Waiting for BLE connection and notification subscription…"
                    } else if self.bluetooth.clockSyncInProgress {
                        self.status = "Waiting for the time-sync write to complete…"
                    } else {
                        self.status = "Waiting for the current BLE payload send to finish…"
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard self.operation == token else { return }
                self.status = "Requesting device diagnostics…"
                self.startedReceiving = true
                self.deadline = ProcessInfo.processInfo.systemUptime + 65
                PhoneDiagnosticLog.shared.record("DIAGNOSTIC_REQUEST_WRITE_STARTED")
                try await self.bluetooth.write(Data("DIAG_EXPORT".utf8), mode: .withResponse)
                guard self.operation == token else { return }
                self.requestWriteConfirmed = true
                PhoneDiagnosticLog.shared.record("DIAGNOSTIC_REQUEST_WRITE_CONFIRMED")
                if self.assembler.exportID == nil && self.awaitingConfirmation == nil {
                    self.status = "Request write acknowledged by BLE. Waiting for the device export header…"
                }
                let transferDeadline = ProcessInfo.processInfo.systemUptime + 65
                while self.operation == token {
                    try Task.checkCancellation()
                    guard self.bluetooth.notificationsReady else { throw DiagnosticError.disconnected }
                    guard ProcessInfo.processInfo.systemUptime < transferDeadline else { throw DiagnosticError.timeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                if self.operation == token { self.fail(error) }
            }
        }
    }

    func cancel() {
        guard busy else { return }
        fail(CancellationError())
    }

    private func receive(_ data: Data) {
        guard busy, startedReceiving else { return }
        do {
            let packet = try DiagnosticPacket(data)
            if packet.kind == 5 {
                guard awaitingConfirmation == nil, packet.body.count == 1,
                      assembler.exportID == nil || assembler.exportID == packet.exportID else { return }
                PhoneDiagnosticLog.shared.record("DIAGNOSTIC_DEVICE_FAILURE", level: "ERROR", value1: Int64(packet.body.first!))
                throw DiagnosticError.deviceFailure(packet.body.first!)
            }
            if packet.kind == 4 {
                guard packet.exportID == awaitingConfirmation, packet.body.isEmpty else { return }
                PhoneDiagnosticLog.shared.record("DIAGNOSTIC_CLEAR_CONFIRMED")
                finish("Saved diagnostics. The device cleared the exported log entries; lifetime metrics were preserved.")
                return
            }
            // Ignore late data after the file is safely saved; ACK retries are idempotent.
            guard awaitingConfirmation == nil else { return }
            let completed = try assembler.accept(packet)
            progress = assembler.total > 0 ? Double(assembler.data.count) / Double(assembler.total) : 0
            status = "Downloading \(assembler.data.count) of \(assembler.total) bytes…"
            if let completed, let id = assembler.exportID { try saveAndAcknowledge(completed, id: id) }
        } catch { fail(error) }
    }

    private static func validCompactEvents(_ device: [String: Any]) -> Bool {
        guard device["compactDeviceColumns"] != nil else {
            return device["deviceChunkLogs"] == nil && device["deviceTransactionLogs"] == nil
        }
        let expected = ["sequence", "uptimeMs", "unixTimeMs", "timestampSynced", "sessionId", "level", "eventCode", "value1", "value2", "transactionId"]
        guard device["compactDeviceColumns"] as? [String] == expected,
              let chunks = device["deviceChunkLogs"] as? [[Any]], chunks.count <= 288,
              let transactions = device["deviceTransactionLogs"] as? [[Any]], transactions.count <= 120,
              (chunks+transactions).allSatisfy({ $0.count == expected.count }) else { return false }
        return DiagnosticInterleave.compactRows(device).allSatisfy { row in
            validEvents([row]) && row["transactionId"] is String
        }
    }
    private static func validEvents(_ events: [[String: Any]]) -> Bool {
        var previous: UInt64 = 0
        for event in events {
            guard let sequence = event["sequence"] as? NSNumber, sequence.uint64Value > previous,
                  event["uptimeMs"] is NSNumber, event["unixTimeMs"] is NSNumber,
                  event["timestampSynced"] is Bool, event["sessionId"] is String,
                  event["eventCode"] is String, event["level"] is String,
                  event["value1"] is NSNumber, event["value2"] is NSNumber else { return false }
            previous = sequence.uint64Value
        }
        return true
    }
    private func saveAndAcknowledge(_ payload: Data, id: UInt32) throws {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let device = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              device["schemaVersion"] as? Int == 1,
              let metadata = device["metadata"] as? [String: Any], device["metrics"] is [String: Any],
              metadata["bootId"] is NSNumber, metadata["uptimeMs"] is NSNumber,
              let logs = device["deviceLogs"] as? [[String: Any]], logs.count <= 256,
              let errors = device["deviceErrors"] as? [[String: Any]], errors.count <= 32,
              Self.validEvents(logs), Self.validEvents(errors), Self.validCompactEvents(device)
        else { throw DiagnosticError.invalidPacket }
        PhoneDiagnosticLog.shared.record("DIAGNOSTIC_PAYLOAD_VALIDATED", value1: Int64(payload.count))
        let phoneLogs = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PhoneDiagnosticLog.shared.snapshot()))
        let combined: [String: Any] = [
            "schemaVersion": 1, "exportId": String(format: "%08x", id),
            "collectedAtUnixMs": Int64(now.timeIntervalSince1970 * 1000),
            "phoneProcessId": PhoneDiagnosticLog.shared.processId,
            "phoneAppVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "phoneAppBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "device": device, "phoneLogs": phoneLogs
        ]
        let file = try JSONSerialization.data(withJSONObject: combined, options: [.prettyPrinted, .sortedKeys])
        let url = directory.appendingPathComponent("diagnostics_\(formatter.string(from: now))_\(String(format: "%08x", id)).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let saved = SavedDiagnostic(url: url, date: now)
            let normal = Data(try DiagnosticInterleave.render(file).utf8)
            let verbose = Data(try DiagnosticInterleave.render(file, verbose: true).utf8)
            // All representations must be durable and verified before authorizing purge.
            // JSON bytes are unchanged by the presentation layer.
            for (target, contents) in [(url, file), (saved.readableURL, normal), (saved.verboseURL, verbose)] {
                try contents.write(to: target, options: .atomic)
                guard try Data(contentsOf: target) == contents else { throw DiagnosticError.save("File verification failed") }
            }
        } catch { throw DiagnosticError.save(error.localizedDescription) }
        savedURL = url; reloadFiles()
        PhoneDiagnosticLog.shared.record("DIAGNOSTIC_FILE_SAVED")
        awaitingConfirmation = id
        status = "File saved. Confirming receipt with the device…"
        let token = operation
        ackTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<5 {
                guard self.operation == token, self.busy else { return }
                do {
                    try Task.checkCancellation()
                    try await self.bluetooth.write(Data(String(format: "DIAG_ACK %08x", id).utf8), mode: .withResponse)
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            if self.operation == token { self.finish("File saved. Device acknowledgement was not confirmed; some exported logs may appear again.") }
        }
    }

    private func timeoutError() -> DiagnosticError {
        if !startedReceiving {
            if !bluetooth.notificationsReady { return .stageTimeout("BLE connection/notification subscription was not ready; request not sent") }
            if bluetooth.clockSyncInProgress { return .stageTimeout("waiting for the time-sync write; request not sent") }
            return .stageTimeout("waiting for the existing BLE payload send; request not sent")
        }
        if assembler.exportID != nil {
            return .stageTimeout("received \(assembler.data.count) of \(assembler.total) bytes; download or final integrity marker did not complete")
        }
        if !requestWriteConfirmed { return .stageTimeout("DIAG_EXPORT write did not receive an ATT acknowledgement") }
        return .stageTimeout("BLE acknowledged DIAG_EXPORT, but no export header or device error arrived; check device Serial [DIAG] messages")
    }
    private func fail(_ error: Error) {
        guard busy else { return }
        let message = savedURL != nil ? "File saved. Device log cleanup was not confirmed." :
            error is CancellationError ? "Download cancelled. No receipt ACK was sent." : error.localizedDescription
        PhoneDiagnosticLog.shared.record("DIAGNOSTIC_COLLECTION_FAILED", level: "ERROR")
        FileLogger.shared.log("[DIAG] " + message)
        // Best effort cancellation never acknowledges or purges an export.
        let canCancel = bluetooth.notificationsReady && !bridge.isSending
        finish(message)
        if canCancel {
            Task { [weak self] in
                guard let self, !self.busy else { return }
                try? await self.bluetooth.write(Data("DIAG_CANCEL".utf8), mode: .withResponse)
            }
        }
    }
    private func finish(_ message: String) {
        operation = nil; requestTask?.cancel(); requestTask = nil; ackTask?.cancel(); ackTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        busy = false; bluetooth.diagnosticsInProgress = false; status = message
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func deleteFiles(at offsets: IndexSet) {
        for file in offsets.map({ files[$0] }) {
            do {
                // Remove only this export and its exact derived filenames.
                for url in [file.readableURL, file.verboseURL, file.url] where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            catch { status = "Could not delete export: \(error.localizedDescription)" }
        }
        reloadFiles()
    }
    func reloadFiles() {
        guard FileManager.default.fileExists(atPath: directory.path) else { files = []; return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            files = urls.filter { ["json", "txt"].contains($0.pathExtension) && !$0.lastPathComponent.hasSuffix(".interleaved.txt") && !$0.lastPathComponent.hasSuffix(".verbose.txt") }.map {
                SavedDiagnostic(url: $0, date: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }.sorted { $0.date > $1.date }
        } catch { status = "Cannot read saved diagnostics: \(error.localizedDescription)" }
    }
}
