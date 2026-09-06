import Combine
import CoreBluetooth
import Foundation

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
        case error(String)

        var title: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .scanning: return "Scanning"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .error: return "Error"
            }
        }

        var message: String {
            switch self {
            case .disconnected: return "Not connected to CTA Tracker."
            case .scanning: return "Looking for CTA Tracker..."
            case .connecting: return "Connecting to CTA Tracker..."
            case .connected: return "Ready to send train data."
            case .error(let message): return message
            }
        }
    }

    static let deviceName = "CTA Tracker"
    static let serviceUUID = CBUUID(string: "7A1C0001-8F4A-4D2B-9A57-1C2D3E4F5001")
    static let characteristicUUID = CBUUID(string: "7A1C0002-8F4A-4D2B-9A57-1C2D3E4F5001")
    private static let dummyPayload = "Morgan|54th/Cermak or Harlem/Lake|Pink:E27EA6:1,3;Green:009B3A:5|Loop or 63rd St|Green:009B3A:5,11;Pink:E27EA6:8"

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastSentPayload: String?
    @Published private(set) var debugMessages: [String] = []
    @Published var showsAllDebugMessages = false {
        didSet { rebuildDebugMessages() }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writableCharacteristic: CBCharacteristic?
    private var allDebugMessages: [DebugMessage] = []
    private var autoScanEnabled = true
    private var userRequestedDisconnect = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        log("Bluetooth manager initialized")
        log("Expected name: \(Self.deviceName)")
        log("Expected service UUID: \(Self.serviceUUID.uuidString)")
        log("Expected characteristic UUID: \(Self.characteristicUUID.uuidString)")
    }

    var canSend: Bool {
        if case .connected = connectionState, writableCharacteristic != nil {
            return true
        }
        return false
    }

    func scanAndConnect() {
        autoScanEnabled = true
        userRequestedDisconnect = false
        startScanning(reason: "manual request")
    }

    private func startScanning(reason: String) {
        guard central.state == .poweredOn else {
            setConnectionState(.error("Bluetooth is not ready."))
            log("Scan blocked: central state is \(central.state.debugName), reason: \(reason)")
            return
        }

        if case .connected = connectionState {
            log("Scan skipped: already connected, reason: \(reason)")
            return
        }

        if case .connecting = connectionState {
            log("Scan skipped: already connecting, reason: \(reason)")
            return
        }

        writableCharacteristic = nil
        peripheral = nil
        setConnectionState(.scanning)
        backgroundLog("scan started: \(reason)")
        log("Scan start: withServices=nil, filtering by advertised/peripheral name \(Self.deviceName), reason: \(reason)")
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func disconnect() {
        log("Disconnect requested; auto scan disabled")
        autoScanEnabled = false
        userRequestedDisconnect = true
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central.stopScan()
        self.peripheral = nil
        writableCharacteristic = nil
        setConnectionState(.disconnected)
    }

    func clearDebugLog() {
        allDebugMessages.removeAll()
        debugMessages.removeAll()
        log("Debug log cleared")
    }

    func sendTrainData(
        stationName: String,
        direction1Name: String,
        direction1ETAs: [Int],
        direction2Name: String,
        direction2ETAs: [Int]
    ) {
        let payload = [
            stationName,
            direction1Name,
            direction1ETAs.prefix(3).map(String.init).joined(separator: ","),
            direction2Name,
            direction2ETAs.prefix(3).map(String.init).joined(separator: ",")
        ].joined(separator: "|")

        send(payload)
    }

    func sendPayload(_ payload: String) {
        send(payload)
    }

    func sendTestData() {
        send(Self.dummyPayload)
    }

    private func send(_ payload: String) {
        guard let peripheral, let characteristic = writableCharacteristic else {
            setConnectionState(.error("CTA Tracker is not ready for writes."))
            log("Write failed: missing peripheral or writable characteristic")
            return
        }

        guard let data = payload.data(using: .utf8) else {
            setConnectionState(.error("Could not encode train data as UTF-8."))
            log("Write failed: payload is not valid UTF-8")
            return
        }

        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        log("Writing \(data.count) bytes using \(writeType.debugName): \(payload)")
        peripheral.writeValue(data, for: characteristic, type: writeType)
        lastSentPayload = payload
    }

    private func setConnectionState(_ state: ConnectionState) {
        connectionState = state
        log("State: \(state.title) - \(state.message)")
    }

    private func log(_ message: String, isRelevant: Bool = true) {
        let entry = "\(Self.debugTimeFormatter.string(from: Date())) \(message)"
        print("[BLE] \(entry)")
        allDebugMessages.append(DebugMessage(text: entry, isRelevant: isRelevant))

        if allDebugMessages.count > 120 {
            allDebugMessages.removeFirst(allDebugMessages.count - 120)
        }

        rebuildDebugMessages()
    }

    private func backgroundLog(_ message: String) {
        print("[BLE BG] \(message)")
    }

    private func rebuildDebugMessages() {
        let visibleMessages = showsAllDebugMessages ? allDebugMessages : allDebugMessages.filter(\.isRelevant)
        debugMessages = visibleMessages.suffix(40).map(\.text)
    }

    private static func debugClassification(
        peripheralName: String?,
        advertisedName: String?,
        advertisementData: [String: Any]
    ) -> (isRelevant: Bool, shouldConnect: Bool, reason: String) {
        let advertisedServiceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflowServiceUUIDs = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceUUIDs = advertisedServiceUUIDs + overflowServiceUUIDs
        let names = [peripheralName, advertisedName].compactMap { $0 }

        if names.contains(Self.deviceName) {
            return (true, true, "exact name match")
        }

        if serviceUUIDs.contains(Self.serviceUUID) {
            return (true, true, "advertises expected service UUID")
        }

        if names.contains(where: { name in
            let lowercasedName = name.lowercased()
            return lowercasedName.contains("cta") || lowercasedName.contains("tracker")
        }) {
            return (true, false, "name looks related")
        }

        return (false, false, "not target")
    }

    private static func formatAdvertisementData(_ advertisementData: [String: Any]) -> String {
        guard !advertisementData.isEmpty else {
            return "[:]"
        }

        let entries = advertisementData.keys.sorted().map { key in
            let value = advertisementData[key]
            return "\(key)=\(formatAdvertisementValue(value))"
        }

        return entries.joined(separator: "; ")
    }

    private static func formatAdvertisementValue(_ value: Any?) -> String {
        switch value {
        case let uuids as [CBUUID]:
            return uuids.map(\.uuidString).joined(separator: ",")
        case let data as Data:
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        case let array as [Any]:
            return array.map { String(describing: $0) }.joined(separator: ",")
        case let dictionary as [AnyHashable: Any]:
            return dictionary.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        case .none:
            return "nil"
        default:
            return String(describing: value!)
        }
    }

    private static let debugTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct DebugMessage {
    let text: String
    let isRelevant: Bool
}

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            log("Central state changed: \(central.state.debugName)")
            backgroundLog("central state: \(central.state.debugName)")

            switch central.state {
            case .poweredOn:
                if case .error = connectionState {
                    setConnectionState(.disconnected)
                }
                if autoScanEnabled {
                    startScanning(reason: "central poweredOn")
                }
            case .poweredOff:
                setConnectionState(.error("Bluetooth is turned off."))
            case .unauthorized:
                setConnectionState(.error("Bluetooth permission is not authorized."))
            case .unsupported:
                setConnectionState(.error("Bluetooth LE is not supported on this device."))
            case .resetting:
                setConnectionState(.error("Bluetooth is resetting."))
            case .unknown:
                setConnectionState(.disconnected)
            @unknown default:
                setConnectionState(.error("Bluetooth is unavailable."))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let peripheralName = peripheral.name
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let classification = Self.debugClassification(
                peripheralName: peripheralName,
                advertisedName: advertisedName,
                advertisementData: advertisementData
            )

            log("Discovered peripheral [\(classification.reason)]", isRelevant: classification.isRelevant)
            log("  name: \(peripheralName ?? "nil")", isRelevant: classification.isRelevant)
            log("  advertisedName: \(advertisedName ?? "nil")", isRelevant: classification.isRelevant)
            log("  identifier: \(peripheral.identifier.uuidString)", isRelevant: classification.isRelevant)
            log("  RSSI: \(RSSI.intValue)", isRelevant: classification.isRelevant)
            log("  advertisementData: \(Self.formatAdvertisementData(advertisementData))", isRelevant: classification.isRelevant)

            guard classification.shouldConnect else {
                return
            }

            if case .connecting = connectionState {
                log("Connect skipped: already connecting")
                return
            }

            if case .connected = connectionState {
                log("Connect skipped: already connected")
                return
            }

            backgroundLog("discovered CTA Tracker: \(peripheral.identifier.uuidString)")
            self.peripheral = peripheral
            peripheral.delegate = self
            setConnectionState(.connecting)
            log("Matched CTA Tracker: \(classification.reason)")
            log("Retained peripheral strongly and assigned peripheral.delegate")
            backgroundLog("connect requested")
            log("connect() called for \(peripheral.identifier.uuidString)")
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            setConnectionState(.connecting)
            backgroundLog("connected")
            log("didConnect for \(peripheral.identifier.uuidString)")
            log("discoverServices called with \(Self.serviceUUID.uuidString)")
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let message = error?.localizedDescription ?? "Failed to connect to CTA Tracker."
            backgroundLog("failed to connect: \(message)")
            log("didFailToConnect: \(message)")
            self.peripheral = nil
            writableCharacteristic = nil

            if autoScanEnabled {
                log("Restarting scan after connect failure")
                startScanning(reason: "connect failed")
            } else {
                setConnectionState(.error(message))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            writableCharacteristic = nil
            self.peripheral = nil

            if let error {
                backgroundLog("disconnected: \(error.localizedDescription)")
                log("didDisconnectPeripheral with error: \(error.localizedDescription)")
            } else {
                backgroundLog("disconnected: no error")
                log("didDisconnectPeripheral: no error")
            }

            let shouldRestartScan = autoScanEnabled && !userRequestedDisconnect
            userRequestedDisconnect = false

            if shouldRestartScan {
                log("Restarting scan after disconnect")
                startScanning(reason: "peripheral disconnected")
            } else {
                setConnectionState(.disconnected)
            }
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                log("Service discovery failed: \(error.localizedDescription)")
                setConnectionState(.error(error.localizedDescription))
                return
            }

            let discoveredServices = peripheral.services ?? []
            if discoveredServices.isEmpty {
                log("No services discovered")
            } else {
                for service in discoveredServices {
                    backgroundLog("service discovered: \(service.uuid.uuidString)")
                    log("Discovered service UUID: \(service.uuid.uuidString)")
                }
            }

            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                setConnectionState(.error("CTA Tracker service was not found."))
                return
            }

            log("Discovering characteristic \(Self.characteristicUUID.uuidString)")
            peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                log("Characteristic discovery failed: \(error.localizedDescription)")
                setConnectionState(.error(error.localizedDescription))
                return
            }

            let characteristics = service.characteristics?.map { characteristic in
                "\(characteristic.uuid.uuidString) [\(characteristic.properties.debugNames)]"
            }.joined(separator: ", ") ?? "none"
            log("Discovered characteristics: \(characteristics)")

            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.characteristicUUID }) else {
                setConnectionState(.error("CTA Tracker write characteristic was not found."))
                return
            }

            guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
                setConnectionState(.error("CTA Tracker characteristic is not writable."))
                return
            }

            writableCharacteristic = characteristic
            backgroundLog("writable characteristic discovered: \(characteristic.uuid.uuidString) [\(characteristic.properties.debugNames)]")
            log("Writable characteristic ready: \(characteristic.properties.debugNames)")
            setConnectionState(.connected)
            backgroundLog("AUTO-SEND: \(Self.dummyPayload)")
            sendTestData()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                backgroundLog("auto-send failed: \(error.localizedDescription)")
                log("Write response failed: \(error.localizedDescription)")
                setConnectionState(.error(error.localizedDescription))
            } else {
                backgroundLog("auto-send/write callback succeeded")
                log("Write response received for \(characteristic.uuid.uuidString)")
            }
        }
    }
}

private extension CBManagerState {
    var debugName: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unavailable"
        }
    }
}

private extension CBCharacteristicProperties {
    var debugNames: String {
        var names: [String] = []

        if contains(.read) { names.append("read") }
        if contains(.write) { names.append("write") }
        if contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if contains(.notify) { names.append("notify") }
        if contains(.indicate) { names.append("indicate") }

        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

private extension CBCharacteristicWriteType {
    var debugName: String {
        switch self {
        case .withResponse: return "withResponse"
        case .withoutResponse: return "withoutResponse"
        @unknown default: return "unknown"
        }
    }
}
