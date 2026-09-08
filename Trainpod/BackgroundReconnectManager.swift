import Combine
import CoreBluetooth
import Foundation
import UIKit

/// Opt-in experiment; retains the already connected central/peripheral pair.
@MainActor
final class BackgroundReconnectManager: ObservableObject {
    static weak var active: BackgroundReconnectManager?
    static let armedNotification = Notification.Name("BackgroundReconnectTestArmed")
    @Published private(set) var isArmed = false
    @Published private(set) var isPending = false
    @Published private(set) var status = "Connect normally, then arm this test."
    @Published private(set) var backgroundReconnectCount = UserDefaults.standard.integer(forKey: "backgroundReconnectCount")
    @Published private(set) var lastBackgroundReconnect = UserDefaults.standard.object(forKey: "lastBackgroundReconnect") as? Date
    @Published private(set) var lastReconnectWasBackgrounded = UserDefaults.standard.bool(forKey: "lastReconnectWasBackgrounded")
    private var central: CBCentralManager?
    private var knownPeripheral: CBPeripheral?

    func arm(central: CBCentralManager, peripheral: CBPeripheral) {
        guard peripheral.state == .connected, Self.active == nil || Self.active === self else { return }
        self.central = central
        knownPeripheral = peripheral
        central.stopScan()
        Self.active = self
        isArmed = true
        isPending = false
        status = "Armed for \(peripheral.identifier). Send ble off on ESP32."
        print("[RECONNECT] \(status)")
        NotificationCenter.default.post(name: Self.armedNotification, object: self)
    }

    func disarm() {
        isArmed = false
        if Self.active === self { Self.active = nil }
        if isPending, let central, let knownPeripheral { central.cancelPeripheralConnection(knownPeripheral) }
        isPending = false
        central = nil; knownPeripheral = nil
        status = "Disarmed. Reconnect normally to resume other BLE tests."
    }

    func handleDisconnect(_ peripheral: CBPeripheral, systemReconnecting: Bool = false) -> Bool {
        guard isArmed, peripheral === knownPeripheral, let central else { return false }
        isPending = true
        central.stopScan()
        peripheral.delegate = central.delegate as? CBPeripheralDelegate
        if !systemReconnecting {
            central.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        }
        status = "Reconnect pending for known peripheral; no scan, no timeout."
        print("[RECONNECT] \(Date().ISO8601Format()) \(status)")
        return true
    }

    /// Initial connections never count. Called synchronously inside didConnect on the main queue.
    func handleConnected(_ peripheral: CBPeripheral, at timestamp: Date) -> Bool {
        guard isArmed, peripheral === knownPeripheral else { return false }
        guard isPending else { return true }
        isPending = false
        let backgrounded = UIApplication.shared.applicationState == .background
        let defaults = UserDefaults.standard
        defaults.set(timestamp, forKey: "lastBackgroundReconnect")
        defaults.set(defaults.integer(forKey: "backgroundReconnectCount") + 1, forKey: "backgroundReconnectCount")
        defaults.set(backgrounded, forKey: "lastReconnectWasBackgrounded")
        defaults.set(peripheral.identifier.uuidString, forKey: "backgroundReconnectPeripheralID")
        lastBackgroundReconnect = timestamp
        backgroundReconnectCount = defaults.integer(forKey: "backgroundReconnectCount")
        lastReconnectWasBackgrounded = backgrounded
        status = "didConnect: backgrounded=\(backgrounded), count=\(backgroundReconnectCount)."
        print("[RECONNECT] \(timestamp.ISO8601Format()) \(status)")
        return true
    }

    func handleFailure(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard isArmed, peripheral === knownPeripheral else { return false }
        isPending = false
        status = "Reconnect failed: \(error?.localizedDescription ?? "unknown error"). No fallback scan. Disarm and retry."
        print("[RECONNECT] \(status)")
        return true
    }
}
