import Combine
import CoreBluetooth
import Foundation

@MainActor
final class BluetoothService: NSObject, ObservableObject {
    enum BLEWriteMode: String, CaseIterable, Identifiable {
        case withResponse = "With Response"
        case withoutResponse = "Without Response"

        var id: String { rawValue }

        var characteristicWriteType: CBCharacteristicWriteType {
            switch self {
            case .withResponse: return .withResponse
            case .withoutResponse: return .withoutResponse
            }
        }
    }

    enum BLETransportError: LocalizedError {
        case notReady
        case unsupportedWriteMode(BLEWriteMode)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "CTA Tracker is not ready for writes."
            case .unsupportedWriteMode(let mode):
                return "CTA Tracker does not support Write \(mode.rawValue)."
            case .writeFailed(let message):
                return message
            }
        }
    }

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

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var maximumWriteValueLength: Int?
    @Published private(set) var debugMessages: [String] = []
    @Published var showsAllDebugMessages = false {
        didSet { rebuildDebugMessages() }
    }

    var receivedDataHandler: ((Data) -> Void)?
    var readyHandler: (() -> Void)?
    var connectionStateHandler: ((ConnectionState) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writableCharacteristic: CBCharacteristic?
    private var pendingWriteContinuation: CheckedContinuation<Void, Error>?
    private var pendingWithoutResponseContinuation: CheckedContinuation<Void, Error>?
    private var writeInProgress = false
    private var allDebugMessages: [DebugMessage] = []
    private var autoScanEnabled = true
    private var userRequestedDisconnect = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        log("Bluetooth service initialized")
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

    var notificationsReady: Bool {
        canSend && writableCharacteristic?.isNotifying == true
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
        connectedDeviceName = nil
        maximumWriteValueLength = nil
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
        connectedDeviceName = nil
        maximumWriteValueLength = nil
        resumePendingWrite(with: .failure(BLETransportError.writeFailed("Disconnected before write completed.")))
        setConnectionState(.disconnected)
    }

    func clearDebugLog() {
        allDebugMessages.removeAll()
        debugMessages.removeAll()
        log("Debug log cleared")
    }

    func maximumWriteValueLength(for mode: BLEWriteMode) -> Int {
        peripheral?.maximumWriteValueLength(for: mode.characteristicWriteType) ?? 0
    }

    var preferredWriteMode: BLEWriteMode {
        writableCharacteristic?.properties.contains(.write) == true ? .withResponse : .withoutResponse
    }

    /// One transport write only. Logical fragmentation belongs to MessageBridge.
    func write(_ data: Data, mode: BLEWriteMode) async throws {
        try Task.checkCancellation()
        guard let peripheral, let characteristic = writableCharacteristic else {
            throw BLETransportError.notReady
        }

        guard supports(mode, characteristic: characteristic) else {
            throw BLETransportError.unsupportedWriteMode(mode)
        }

        guard data.count <= maximumWriteValueLength(for: mode) else {
            throw BLETransportError.writeFailed("Transport write exceeds the negotiated maximum.")
        }
        guard !writeInProgress else {
            throw BLETransportError.writeFailed("A transport write is already pending.")
        }
        writeInProgress = true
        defer { writeInProgress = false }
        try await writeChunk(data, to: characteristic, on: peripheral, type: mode.characteristicWriteType)
    }

    private func supports(_ mode: BLEWriteMode, characteristic: CBCharacteristic) -> Bool {
        switch mode {
        case .withResponse:
            return characteristic.properties.contains(.write)
        case .withoutResponse:
            return characteristic.properties.contains(.writeWithoutResponse)
        }
    }

    private func writeChunk(
        _ data: Data,
        to characteristic: CBCharacteristic,
        on peripheral: CBPeripheral,
        type: CBCharacteristicWriteType
    ) async throws {
        switch type {
        case .withResponse:
            try await withCheckedThrowingContinuation { continuation in
                pendingWriteContinuation = continuation
                peripheral.writeValue(data, for: characteristic, type: type)
            }
        case .withoutResponse:
            while !peripheral.canSendWriteWithoutResponse {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pendingWithoutResponseContinuation = continuation
                }
                try Task.checkCancellation()
                guard self.peripheral === peripheral else { throw BLETransportError.notReady }
            }
            peripheral.writeValue(data, for: characteristic, type: type)
        @unknown default:
            throw BLETransportError.writeFailed("Unknown BLE write type.")
        }
    }

    private func resumePendingWrite(with result: Result<Void, Error>) {
        if case .failure(let error) = result, let waiting = pendingWithoutResponseContinuation {
            pendingWithoutResponseContinuation = nil
            waiting.resume(throwing: error)
        }
        guard let continuation = pendingWriteContinuation else {
            return
        }

        pendingWriteContinuation = nil
        continuation.resume(with: result)
    }

    private func setConnectionState(_ state: ConnectionState) {
        connectionState = state
        log("State: \(state.title) - \(state.message)")
        connectionStateHandler?(state)
        if state == .connected { readyHandler?() }
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

extension BluetoothService: CBCentralManagerDelegate {
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
            connectedDeviceName = nil
            maximumWriteValueLength = nil
            resumePendingWrite(with: .failure(BLETransportError.writeFailed(message)))

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
            connectedDeviceName = nil
            maximumWriteValueLength = nil
            resumePendingWrite(with: .failure(BLETransportError.writeFailed(error?.localizedDescription ?? "Peripheral disconnected.")))

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

extension BluetoothService: CBPeripheralDelegate {
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
            connectedDeviceName = peripheral.name ?? Self.deviceName
            maximumWriteValueLength = peripheral.maximumWriteValueLength(for: .withResponse)
            backgroundLog("writable characteristic discovered: \(characteristic.uuid.uuidString) [\(characteristic.properties.debugNames)]")
            log("Writable characteristic ready: \(characteristic.properties.debugNames)")
            log("Maximum write length with response: \(peripheral.maximumWriteValueLength(for: .withResponse))")
            log("Maximum write length without response: \(peripheral.maximumWriteValueLength(for: .withoutResponse))")
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                setConnectionState(.connecting)
                peripheral.setNotifyValue(true, for: characteristic)
                log("Requesting ACK notification subscription")
            } else {
                setConnectionState(.connected)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Capture callback data before hopping to the main actor; the characteristic is mutable.
        let received = characteristic.value
        Task { @MainActor in
            guard peripheral === self.peripheral, characteristic === writableCharacteristic else { return }
            if let error {
                log("Notification update failed: \(error.localizedDescription)")
                return
            }

            guard let data = received else {
                log("Notification update had no data")
                return
            }

            receivedDataHandler?(data)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard peripheral === self.peripheral, characteristic === writableCharacteristic else { return }
            if let error {
                setConnectionState(.error("ACK subscription failed: \(error.localizedDescription)"))
            } else if characteristic.isNotifying {
                log("ACK notification subscription confirmed")
                setConnectionState(.connected)
            } else {
                setConnectionState(.error("ACK notifications are disabled. Reconnect before testing."))
            }
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
                resumePendingWrite(with: .failure(BLETransportError.writeFailed(error.localizedDescription)))
                setConnectionState(.error(error.localizedDescription))
            } else {
                backgroundLog("auto-send/write callback succeeded")
                log("Write response received for \(characteristic.uuid.uuidString)")
                resumePendingWrite(with: .success(()))
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let continuation = pendingWithoutResponseContinuation else {
                return
            }

            pendingWithoutResponseContinuation = nil
            continuation.resume()
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
