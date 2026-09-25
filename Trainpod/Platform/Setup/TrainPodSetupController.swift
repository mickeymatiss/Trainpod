import Combine
import CoreBluetooth
import Foundation
import UIKit

/// Setup probes a read-only status characteristic. Discovery never sends a claim.
/// A pending binding is retried with exactly the same credentials and deviceId.
@MainActor
final class TrainPodSetupController: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let statusUUID = CBUUID(string: "7A1C0004-8F4A-4D2B-9A57-1C2D3E4F5001")
    static let commandUUID = CBUUID(string: "7A1C0005-8F4A-4D2B-9A57-1C2D3E4F5001")
    static let resultUUID = CBUUID(string: "7A1C0006-8F4A-4D2B-9A57-1C2D3E4F5001")
    @Published private(set) var message = "Looking for your TrainPod…"
    @Published private(set) var showingSuccess = false
    var onComplete: (() -> Void)?
    private let store = TrainPodBindingStore.shared
    private let configuration = TransitBLEConfiguration.current
    private var central: CBCentralManager!
    private var timer: Timer?
    private var running = false
    private var candidates: [UUID: CBPeripheral] = [:]
    private var lastSeen: [UUID: Date] = [:]
    private var lastProbe: [UUID: Date] = [:]
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var result: CBCharacteristic?
    private var deviceId: String?
    private var deadline = Date.distantFuture
    private var nextResultRead = Date.distantFuture
    private var frames: [Data] = []
    private var frameIndex = 0
    private var transaction: UInt32 = 0
    private var recovering = false
    private var waitingResult = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    private func log(_ text: String) { FileLogger.shared.log("[SETUP] \(text)") }
    @objc private func resume() { if store.bound == nil { start() } }
    func start() {
        store.reload()
        guard store.bound == nil else { stop(); onComplete?(); return }
        guard store.storageError == nil else { message = store.storageError!; stop(); return }
        if !running {
            running = true
            log(store.pending == nil ? "No bound TrainPod" : "Pending binding found")
            log("Scanning for setup-ready TrainPod")
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        scan()
    }
    private func scan() {
        guard running, central.state == .poweredOn else { return }
        if !central.isScanning {
            central.scanForPeripherals(withServices: [configuration.serviceUUID],
                                      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    func stop() {
        running = false; timer?.invalidate(); timer = nil
        central.stopScan(); releaseCandidate()
    }
    private func releaseCandidate() {
        if let peripheral {
            lastProbe[peripheral.identifier] = Date()
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil; command = nil; result = nil; deviceId = nil
        frames = []; frameIndex = 0; transaction = 0; waitingResult = false
        nextResultRead = .distantFuture; deadline = .distantFuture
    }
    private func tick() {
        guard running, !showingSuccess, store.bound == nil else { return }
        scan()
        guard central.state == .poweredOn else { return }
        if let peripheral {
            if Date() >= deadline { log("Setup attempt timed out; pending credentials retained"); releaseCandidate(); return }
            if waitingResult, Date() >= nextResultRead, let result {
                nextResultRead = Date().addingTimeInterval(1)
                peripheral.readValue(for: result)
            }
            return
        }
        message = store.pending != nil ? "Reconnecting to your TrainPod…" : candidates.isEmpty ? "Looking for your TrainPod…" : "Press the button on your TrainPod"
        let now = Date()
        let available = candidates.values.filter {
            now.timeIntervalSince(lastSeen[$0.identifier] ?? .distantPast) < 60 &&
            now.timeIntervalSince(lastProbe[$0.identifier] ?? .distantPast) > 2 && $0.state == .disconnected
        }.sorted { (lastProbe[$0.identifier] ?? .distantPast) < (lastProbe[$1.identifier] ?? .distantPast) }
        guard let candidate = available.first else { return }
        peripheral = candidate; candidate.delegate = self; deadline = now.addingTimeInterval(8)
        central.connect(candidate, options: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { if running { scan() } }
        else {
            releaseCandidate()
            message = central.state == .unauthorized ? "Allow Bluetooth access in Settings." : "Turn on Bluetooth to set up TrainPod."
            if central.state == .resetting { candidates = [:]; lastSeen = [:]; lastProbe = [:] }
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running else { return }
        candidates[peripheral.identifier] = peripheral; lastSeen[peripheral.identifier] = Date()
        if self.peripheral == nil { message = "Press the button on your TrainPod" }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running, peripheral === self.peripheral else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.discoverServices([configuration.serviceUUID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral === self.peripheral { releaseCandidate() }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === self.peripheral { releaseCandidate() }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == configuration.serviceUUID }),
              let identity = configuration.deviceIdentityUUID else { releaseCandidate(); return }
        peripheral.discoverCharacteristics([identity, Self.statusUUID, Self.commandUUID, Self.resultUUID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        let chars = service.characteristics ?? []
        guard error == nil, let identity = chars.first(where: { $0.uuid == configuration.deviceIdentityUUID }),
              let status = chars.first(where: { $0.uuid == Self.statusUUID }),
              let command = chars.first(where: { $0.uuid == Self.commandUUID }),
              let result = chars.first(where: { $0.uuid == Self.resultUUID }),
              identity.properties.contains(.read), status.properties.contains(.read),
              command.properties.contains(.write), result.properties.contains(.read) else {
            message = "TrainPod needs setup-capable firmware."; releaseCandidate(); return
        }
        self.command = command; self.result = result
        peripheral.readValue(for: identity)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, running else { return }
        guard error == nil, let data = characteristic.value else { releaseCandidate(); return }
        if characteristic.uuid == configuration.deviceIdentityUUID {
            guard let id = String(data: data, encoding: .utf8), TrainPodBindingStore.validDeviceId(id),
                  store.pending == nil || store.pending?.deviceId == id else { releaseCandidate(); return }
            deviceId = id
            guard let status = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.statusUUID }) else { releaseCandidate(); return }
            peripheral.readValue(for: status)
        } else if characteristic.uuid == Self.statusUUID {
            guard data.count == 2, data[0] == 1, let id = deviceId else { releaseCandidate(); return }
            let state = data[1]
            if state == 3 { message = "TrainPod storage is unavailable. Restart TrainPod, then retry."; stop(); return }
            guard state == 1 || (state == 2 && store.pending?.deviceId == id) else { releaseCandidate(); return }
            do {
                let binding = try store.prepare(deviceId: id, peripheral: peripheral.identifier)
                recovering = state == 2
                log(recovering ? "Attempting binding recovery" : "Found setup-ready device")
                log("Device ID: \(id)")
                beginRequest(binding, on: peripheral)
            } catch { message = error.localizedDescription; stop() }
        } else if characteristic.uuid == Self.resultUUID, waitingResult {
            guard data.count == 6, data[0] == 1 else { return }
            let token = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[1+$1]) << (8*$1) }
            guard token == transaction else { return }
            if data[5] == 1, let id = deviceId {
                do {
                    // Keep the acknowledgement on screen before normal runtime takes over.
                    showingSuccess = true
                    // Persist the unfinished preferences step before publishing the binding.
                    // An interrupted app launch resumes it for this physical device.
                    TrainPodSetupPreferences.begin(for: id)
                    try store.promote(deviceId: id, peripheral: peripheral.identifier)
                    message = "TrainPod connected ✓"
                    log(recovering ? "Binding recovered successfully" : "Claim successful")
                    stop()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        self?.showingSuccess = false; self?.onComplete?()
                    }
                } catch { showingSuccess = false; message = error.localizedDescription; stop() }
            } else if data[5] != 0 {
                log("Claim/recovery rejected (code \(data[5])); pending credentials retained")
                releaseCandidate()
            }
        }
    }
    private func beginRequest(_ binding: TrainPodBinding, on peripheral: CBPeripheral) {
        guard let command else { return }
        var uuid = binding.appInstallationId.uuid
        var credentials = withUnsafeBytes(of: &uuid) { Data($0) }
        credentials.append(binding.bindingKey)
        transaction = UInt32.random(in: 1...UInt32.max)
        let op: UInt8 = recovering ? 2 : 1
        frames = (0..<4).map { index in
            var frame = Data([op])
            for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8(truncatingIfNeeded: transaction >> shift)) }
            frame.append(UInt8(index))
            frame.append(credentials.subdata(in: index*14..<min(index*14+14, 48)))
            return frame
        }
        // Each command fits even the default 20-byte ATT payload.
        guard peripheral.maximumWriteValueLength(for: .withResponse) >= 20 else { releaseCandidate(); return }
        frameIndex = 0; deadline = Date().addingTimeInterval(10)
        message = "Connecting…"; log(recovering ? "Sending recovery proof" : "Sending claim")
        peripheral.writeValue(frames[0], for: command, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === command, !frames.isEmpty else { return }
        guard error == nil else { releaseCandidate(); return }
        frameIndex += 1
        if frameIndex < frames.count {
            peripheral.writeValue(frames[frameIndex], for: characteristic, type: .withResponse)
        } else {
            frames = []; waitingResult = true; nextResultRead = Date()
        }
    }
}
