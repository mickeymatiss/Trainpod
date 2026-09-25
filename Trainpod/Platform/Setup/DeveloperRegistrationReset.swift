import Combine
import CoreBluetooth
import Foundation
import SwiftUI

/// Separate, explicitly invoked setup transaction. Never participates in normal BLE traffic.
@MainActor
final class DeveloperRegistrationReset: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var busy = false
    @Published private(set) var message = "Reset registration on your TrainPod and this app."
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var binding: TrainPodBinding?
    private var command: CBCharacteristic?
    private var result: CBCharacteristic?
    private var frames: [Data] = []
    private var frameIndex = 0
    private var transaction: UInt32 = 0
    private var verified = false
    private var waitingResult = false
    private var readPending = false
    private var timer: Timer?
    private var deadline = Date.distantFuture
    private var onSuccess: (() -> Void)?
    private let configuration = TransitBLEConfiguration.current

    func start(onSuccess: @escaping () -> Void) {
        guard !busy else { return }
        guard let binding = TrainPodBindingStore.shared.bound,
              binding.bindingKey.count == 32 else {
            message = "No registered device is available to reset."; return
        }
        let runtime = BLERuntime.shared
        guard !runtime.diagnostics.busy, !runtime.bridge.isSending else {
            message = "Wait for the current transfer or diagnostics download to finish."; return
        }
        self.binding = binding; self.onSuccess = onSuccess
        busy = true; verified = false; waitingResult = false; readPending = false
        deadline = Date().addingTimeInterval(25)
        message = "Connecting to the registered TrainPod. Keep it awake and this app open."
        // User explicitly selected reset. Stop normal owners only for this operation.
        runtime.setup.stop()
        runtime.bluetooth.disconnect()
        runtime.testBluetooth.disconnect()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
        if central?.state == .poweredOn { connectRegisteredDevice() }
    }

    private func tick() {
        guard busy else { return }
        if Date() >= deadline {
            fail("Reset not confirmed. App registration was retained. Keep TrainPod awake, then retry; if the device already reset, retry will detect it.")
        } else if waitingResult, !readPending, let peripheral, let result {
            readPending = true
            peripheral.readValue(for: result)
        }
    }

    private func connectRegisteredDevice() {
        guard busy, peripheral == nil, let central, let id = binding?.peripheralIdentifier else {
            if busy && binding?.peripheralIdentifier == nil { fail("No saved peripheral identifier. Reconnect normally before resetting.") }
            return
        }
        if let target = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(target)
        } else {
            central.scanForPeripherals(withServices: [configuration.serviceUUID], options: nil)
        }
    }

    private func connect(_ target: CBPeripheral) {
        guard busy, peripheral == nil else { return }
        central?.stopScan()
        peripheral = target; target.delegate = self
        central?.connect(target, options: nil)
    }

    private func stop() {
        busy = false
        timer?.invalidate(); timer = nil
        central?.stopScan()
        let old = peripheral
        peripheral = nil; command = nil; result = nil
        frames.removeAll(); binding = nil; waitingResult = false; verified = false
        if let old { central?.cancelPeripheralConnection(old) }
    }

    private func fail(_ reason: String) {
        stop(); onSuccess = nil
        message = reason
    }

    func cancelIfNeeded() {
        guard busy else { return }
        fail("Reset confirmation interrupted. App registration was retained; retry to check the device’s state.")
    }

    private func confirmed() {
        guard busy, verified, let binding else { return }
        guard TrainPodBindingStore.shared.bound == binding else {
            fail("App registration changed during reset. The new app binding was not cleared."); return
        }
        do {
            // Only now remove the active binding. Other saved devices remain intact.
            // Failed Keychain writes preserve the old item, allowing another attempt.
            try TrainPodBindingStore.shared.resetInstallationForDevelopment()
            let completion = onSuccess; onSuccess = nil
            stop()
            message = "Registration reset. Press TrainPod’s button to start fresh setup."
            completion?()
        } catch {
            fail("Device registration is reset, but the app reset failed: \(error.localizedDescription). Retry to finish clearing the app.")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard busy else { return }
        if central.state == .poweredOn { connectRegisteredDevice() }
        else if central.state != .unknown && central.state != .resetting {
            fail("Bluetooth is unavailable. App registration was retained; enable Bluetooth and retry.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard busy, peripheral.identifier == binding?.peripheralIdentifier else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard busy, peripheral === self.peripheral else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.discoverServices([configuration.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard busy, peripheral === self.peripheral else { return }
        fail("Could not connect. App registration was retained. Wake TrainPod and retry.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard busy, peripheral === self.peripheral else { return }
        fail("Disconnected before reset confirmation. App registration was retained. Retry to check the device’s state.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard busy, peripheral === self.peripheral else { return }
        guard error == nil, let identity = configuration.deviceIdentityUUID,
              let service = peripheral.services?.first(where: { $0.uuid == configuration.serviceUUID }) else {
            fail("Setup service unavailable. App registration was retained."); return
        }
        peripheral.discoverCharacteristics([identity, TrainPodSetupController.statusUUID,
            TrainPodSetupController.commandUUID, TrainPodSetupController.resultUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard busy, peripheral === self.peripheral, service.uuid == configuration.serviceUUID else { return }
        let chars = service.characteristics ?? []
        guard error == nil,
              let identity = chars.first(where: { $0.uuid == configuration.deviceIdentityUUID }),
              let status = chars.first(where: { $0.uuid == TrainPodSetupController.statusUUID }),
              let command = chars.first(where: { $0.uuid == TrainPodSetupController.commandUUID }),
              let result = chars.first(where: { $0.uuid == TrainPodSetupController.resultUUID }),
              identity.properties.contains(.read), status.properties.contains(.read),
              command.properties.contains(.write), result.properties.contains(.read) else {
            fail("Install reset-capable firmware before using this action. App registration was retained."); return
        }
        self.command = command; self.result = result
        peripheral.readValue(for: identity)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard busy, peripheral === self.peripheral else { return }
        guard error == nil, let data = characteristic.value else {
            fail("Reset response could not be read. App registration was retained; retry to check device state."); return
        }
        if characteristic.uuid == configuration.deviceIdentityUUID {
            guard String(data: data, encoding: .utf8) == binding?.deviceId else {
                fail("Device identity did not match. Nothing was reset."); return
            }
            verified = true
            guard let status = characteristic.service?.characteristics?.first(where: { $0.uuid == TrainPodSetupController.statusUUID }) else {
                fail("Setup status unavailable. Nothing was reset."); return
            }
            peripheral.readValue(for: status)
        } else if characteristic.uuid == TrainPodSetupController.statusUUID, verified {
            guard data.count == 2, data[0] == 1 else { fail("Unsupported setup status. App registration retained."); return }
            if data[1] == 0 || data[1] == 1 {
                // Recovery after a lost reset result: this exact device is already unbound.
                confirmed()
            } else if data[1] == 2 { sendReset() }
            else { fail("Device storage is unavailable. Nothing was reset.") }
        } else if characteristic === result, waitingResult {
            readPending = false
            guard data.count == 6, data[0] == 1 else { return }
            let token = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[1+$1]) << (8*$1) }
            guard token == transaction, data[5] != 0 else { return }
            if data[5] == 1 { confirmed() }
            else { fail("Device rejected reset (code \(data[5])). App registration retained. Check firmware version and binding.") }
        }
    }

    private func sendReset() {
        guard verified, let binding, let peripheral, let command else { return }
        guard peripheral.maximumWriteValueLength(for: .withResponse) >= 20 else { fail("BLE write capacity unavailable. Nothing was reset."); return }
        var uuid = binding.appInstallationId.uuid
        var credentials = withUnsafeBytes(of: &uuid) { Data($0) }
        credentials.append(binding.bindingKey)
        transaction = UInt32.random(in: 1...UInt32.max)
        frames = (0..<4).map { index in
            var frame = Data([UInt8(3)]) // Authenticated registration reset.
            for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8(truncatingIfNeeded: transaction >> shift)) }
            frame.append(UInt8(index))
            frame.append(credentials.subdata(in: index*14..<min(index*14+14, 48)))
            return frame
        }
        frameIndex = 0
        message = "Resetting device registration. Keep the app open until confirmed."
        peripheral.writeValue(frames[0], for: command, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard busy, peripheral === self.peripheral, characteristic === command, !frames.isEmpty else { return }
        guard error == nil else { fail("Reset write failed. App registration retained; retry to check device state."); return }
        frameIndex += 1
        if frameIndex < frames.count { peripheral.writeValue(frames[frameIndex], for: characteristic, type: .withResponse) }
        else { frames.removeAll(); waitingResult = true; readPending = false }
    }
}

struct DeveloperRegistrationResetView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reset = DeveloperRegistrationReset()
    @State private var confirming = false
    let onReset: () -> Void

    var body: some View {
        Form {
            Section("Fresh registration flow") {
                Text("Clears the active device’s registration on the device and this iPhone. Other saved TrainPods are kept. Afterward, register again or select a saved device.")
                Text("Permanent device ID, themes, arrivals, logs, app preferences, and iOS permissions are kept. This is a registration reset, not a factory erase.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Install the updated firmware first. Hold the device button for two seconds to keep BLE available, then leave this app open during reset.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(reset.message)
                if reset.busy { ProgressView() }
                Button("Reset device + app registration", role: .destructive) { confirming = true }
                    .disabled(reset.busy)
            }
        }
        .navigationTitle("Reset registration")
        .navigationBarBackButtonHidden(reset.busy)
        .onDisappear { reset.cancelIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { reset.cancelIfNeeded() }
        }
        .confirmationDialog("Reset registration on both sides?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset registration", role: .destructive) { reset.start(onSuccess: onReset) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your registered TrainPod must be nearby. The app keeps its binding until the device confirms reset. You will need to register again.")
        }
    }
}
