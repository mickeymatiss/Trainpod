import Combine
import CoreBluetooth
import Foundation
import UIKit
import OSLog

@MainActor
final class BluetoothService: NSObject, ObservableObject {
    let backgroundReconnect = BackgroundReconnectManager()
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
        case notReady(String)
        case unsupportedWriteMode(BLEWriteMode, String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReady(let device):
                return "\(device) is not ready for writes."
            case .unsupportedWriteMode(let mode, let device):
                return "\(device) does not support Write \(mode.rawValue)."
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

        func message(configuration: BLEConfiguration) -> String {
            switch self {
            case .disconnected: return "Not connected to \(configuration.deviceName)."
            case .scanning: return "Looking for \(configuration.deviceName)..."
            case .connecting: return "Connecting to \(configuration.deviceName)..."
            case .connected: return configuration.connectedMessage
            case .error(let message): return message
            }
        }
    }

    let configuration: BLEConfiguration
    var deviceName: String { configuration.deviceName }
    var connectionMessage: String { connectionState.message(configuration: configuration) }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedDeviceName: String?
    // Authoritative physical identity; verified before enabling transit traffic.
    @Published private(set) var connectedDeviceId: String?
    @Published private(set) var maximumWriteValueLength: Int?
    @Published private(set) var debugMessages: [String] = []
    @Published private(set) var lifecycleDiagnostics: [String] = []
    @Published var showsAllDebugMessages = false {
        didSet { rebuildDebugMessages() }
    }

    var viewModeAcknowledgementHandler: ((Data) -> Void)?
    var viewModeConnectionStateHandler: ((ConnectionState) -> Void)?
    var viewModeReadyHandler: (() -> Void)?
    var uiColorAcknowledgementHandler: ((Data) -> Void)?
    var uiColorConnectionStateHandler: ((ConnectionState) -> Void)?
    var receivedDataHandler: ((Data) -> Void)?
    var diagnosticDataHandler: ((Data) -> Void)?
    @Published var diagnosticsInProgress = false
    private(set) var clockSyncInProgress = false
    private(set) var diagnosticSessionId = ""
    private var clockSyncStarted = false
    private var clockSyncTask: Task<Void, Never>?
    @Published private(set) var recentDeviceRequests: [ReceivedDeviceRequest] = []
    var controlMessageHandler: ((Date, Bool, PayloadTransaction?) -> Void)?
    var dataAppliedHandler: ((PayloadTransaction, UInt8, Int) -> Void)?
    var connectionEndedHandler: (() -> Void)?
    var readyHandler: (() -> Void)?
    var connectionStateHandler: ((ConnectionState) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writableCharacteristic: CBCharacteristic?
    private var pendingWriteContinuation: CheckedContinuation<Void, Error>?
    private var pendingWriteCharacteristic: CBCharacteristic?
    private var pendingWithoutResponseContinuation: CheckedContinuation<Void, Error>?
    private var writeInProgress = false
    private var allDebugMessages: [DebugMessage] = []
    private var autoScanEnabled = true
    private var userRequestedDisconnect = false
    private let role: String
    private let defaults: UserDefaults
    private var restorationID: String { "\(configuration.restorationPrefix).\(role).v1" }
    private var intentKey: String { "ble.\(role).wantsConnection" }
    private var knownKey: String { "ble.\(role).knownPeripheral" }
    private var diagnosticsKey: String { "ble.\(role).lifecycleLog" }
    private static let processSession = UUID().uuidString
    private let logger: Logger
    private var dataPathStarted = false
    private var retrieveAfterReset = false
    private var connectionRequestPending = false
    private var rejectedCandidates: [UUID: Date] = [:]
    private var identityVerificationTask: Task<Void, Never>?
    private var bindingAllowsConnection: Bool {
        configuration.deviceIdentityUUID == nil || TrainPodBindingStore.shared.bound != nil
    }
    private var identityVerified: Bool {
        configuration.deviceIdentityUUID == nil ||
        (connectedDeviceId != nil && connectedDeviceId == TrainPodBindingStore.shared.bound?.deviceId)
    }
    private func rejectUnregisteredPeripheral(_ candidate: CBPeripheral) {
        guard peripheral === candidate else { return }
        log("Candidate did not verify as the registered TrainPod")
        rejectedCandidates[candidate.identifier] = Date().addingTimeInterval(15)
        identityVerificationTask?.cancel()
        central.cancelPeripheralConnection(candidate)
        self.peripheral = nil; writableCharacteristic = nil; connectedDeviceId = nil
        dataPathStarted = false; connectionRequestPending = false
        defaults.removeObject(forKey: knownKey)
        setConnectionState(.disconnected)
        if autoScanEnabled && bindingAllowsConnection { startScanning(reason: "search for registered device identity") }
    }

    init(configuration: BLEConfiguration, role: String, autoConnect: Bool = true, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.logger = Logger(subsystem: configuration.loggerSubsystem, category: "BLELifecycle")
        self.role = role
        self.defaults = defaults
        super.init()
        autoScanEnabled = defaults.object(forKey: intentKey) as? Bool ?? autoConnect
        lifecycleDiagnostics = defaults.stringArray(forKey: diagnosticsKey) ?? []
        if let hint = TrainPodBindingStore.shared.bound?.peripheralIdentifier {
            defaults.set(hint.uuidString, forKey: knownKey)
        }
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: restorationID])
        NotificationCenter.default.addObserver(self, selector: #selector(reconnectTestArmed), name: BackgroundReconnectManager.armedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enteredForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        diagnostic("central initialized restoreID=\(restorationID) process=\(Self.processSession) wantsConnection=\(autoScanEnabled)")
        log("Bluetooth service initialized")
        log("Expected name: \(configuration.deviceName)")
        log("Expected service UUID: \(configuration.serviceUUID.uuidString)")
        log("Expected characteristic UUID: \(configuration.characteristicUUID.uuidString)")
    }

    var canSend: Bool {
        guard bindingAllowsConnection, identityVerified, BackgroundReconnectManager.active == nil,
              central.state == .poweredOn, peripheral?.state == .connected else { return false }
        if case .connected = connectionState, writableCharacteristic != nil {
            return true
        }
        return false
    }

    var notificationsReady: Bool {
        canSend && writableCharacteristic?.isNotifying == true
    }

    func scanAndConnect() {
        guard bindingAllowsConnection, BackgroundReconnectManager.active == nil else { return }
        if peripheral == nil, let hint = TrainPodBindingStore.shared.bound?.peripheralIdentifier {
            defaults.set(hint.uuidString, forKey: knownKey)
        }
        autoScanEnabled = true
        defaults.set(true, forKey: intentKey)
        userRequestedDisconnect = false
        resumeKnownConnection(reason: "manual request")
    }

    private func startScanning(reason: String) {
        guard bindingAllowsConnection, BackgroundReconnectManager.active == nil else { return }
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

        if peripheral != nil {
            resumeKnownConnection(reason: reason)
            return
        }
        writableCharacteristic = nil
        connectedDeviceId = nil
        connectedDeviceName = nil
        maximumWriteValueLength = nil
        setConnectionState(.scanning)
        FileLogger.shared.log("[BLE] Scan started role=\(role)")
        backgroundLog("scan started: \(reason)")
        log("Scan start: expected service UUID, reason: \(reason)")
        central.scanForPeripherals(withServices: [configuration.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        diagnostic("scan started service=\(configuration.serviceUUID.uuidString) reason=\(reason)")
        PhoneDiagnosticLog.shared.record("BLE_SCAN_STARTED", sessionId: diagnosticSessionId)
    }

    func disconnect() {
        connectionEndedHandler?()
        backgroundReconnect.disarm()
        log("Disconnect requested; auto scan disabled")
        autoScanEnabled = false
        defaults.set(false, forKey: intentKey)
        userRequestedDisconnect = true
        if let peripheral {
            diagnostic("cancelPeripheralConnection: explicit user disconnect id=\(peripheral.identifier)")
            central.cancelPeripheralConnection(peripheral)
        }
        stopScanning(reason: "explicit user disconnect")
        self.peripheral = nil
        dataPathStarted = false
        connectionRequestPending = false
        writableCharacteristic = nil
        connectedDeviceId = nil
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

    func armBackgroundReconnectTest() {
        guard let peripheral, canSend, !writeInProgress else { return }
        backgroundReconnect.arm(central: central, peripheral: peripheral)
        objectWillChange.send()
    }

    @objc private func reconnectTestArmed() {
        // Both existing screens own a service. Silence scans/writes in both during the test.
        stopScanning(reason: "reconnect-only test armed")
        objectWillChange.send()
    }

    @objc private func enteredBackground() {
        diagnostic("app entering background; state=\(connectionState.title) peripheral=\(peripheral?.identifier.uuidString ?? "none")")
    }

    @objc private func enteredForeground() {
        diagnostic("app entering foreground; state=\(connectionState.title)")
        // Reconcile once on lifecycle change, never cancel a pending connection.
        resumeKnownConnection(reason: "foreground reconciliation")
    }

    private func diagnostic(_ message: String) {
        let entry = "\(Date().ISO8601Format()) [\(role)] \(message)"
        logger.notice("\(entry, privacy: .public)")
        lifecycleDiagnostics.append(entry)
        lifecycleDiagnostics = Array(lifecycleDiagnostics.suffix(100))
        defaults.set(lifecycleDiagnostics, forKey: diagnosticsKey)
        log(message)
    }

    private func stopScanning(reason: String) {
        guard central.isScanning else { return }
        central.stopScan()
        diagnostic("scan stopped: \(reason)")
    }

    private func retainKnown(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        if identityVerified { defaults.set(peripheral.identifier.uuidString, forKey: knownKey) }
    }

    private func requestConnection(_ peripheral: CBPeripheral, reason: String) {
        guard bindingAllowsConnection, autoScanEnabled, central.state == .poweredOn else { return }
        retainKnown(peripheral)
        stopScanning(reason: "known peripheral")
        setConnectionState(.connecting)
        if peripheral.state == .connecting || connectionRequestPending {
            connectionRequestPending = true
            diagnostic("connection pending id=\(peripheral.identifier); retained existing request; \(reason)")
            return
        }
        guard peripheral.state == .disconnected else { return }
        connectionRequestPending = true
        central.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        PhoneDiagnosticLog.shared.record("BLE_CONNECT_REQUESTED", sessionId: diagnosticSessionId)
        FileLogger.shared.log("[BLE] Connection requested role=\(role)")
        diagnostic("connection request issued id=\(peripheral.identifier) systemAutoReconnect=true reason=\(reason)")
        diagnostic("connection pending; no application timeout or polling")
    }

    private func resumeKnownConnection(reason: String) {
        guard bindingAllowsConnection, autoScanEnabled, !userRequestedDisconnect,
              BackgroundReconnectManager.active == nil, central.state == .poweredOn else { return }
        if retrieveAfterReset {
            // CoreBluetooth invalidates peripheral objects on a central reset; retrieve the saved ID.
            peripheral = nil
            retrieveAfterReset = false
        }
        if peripheral == nil, let saved = defaults.string(forKey: knownKey), let id = UUID(uuidString: saved) {
            if let retrieved = central.retrievePeripherals(withIdentifiers: [id]).first {
                retainKnown(retrieved)
                diagnostic("known peripheral retrieved id=\(id) state=\(retrieved.state.rawValue)")
            } else {
                diagnostic("known peripheral unavailable to retrieve; service-filtered discovery required")
            }
        }
        guard let peripheral else {
            startScanning(reason: reason)
            return
        }
        peripheral.delegate = self
        switch peripheral.state {
        case .connected: resumeDataPath(peripheral)
        case .connecting, .disconnected: requestConnection(peripheral, reason: reason)
        case .disconnecting: diagnostic("waiting for disconnect callback id=\(peripheral.identifier)")
        @unknown default: diagnostic("unknown peripheral state; retaining known peripheral")
        }
    }

    private func resumeDataPath(_ peripheral: CBPeripheral) {
        guard bindingAllowsConnection, !dataPathStarted else { return }
        connectedDeviceId = nil; writableCharacteristic = nil
        identityVerificationTask?.cancel()
        identityVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.peripheral === peripheral,
                  !self.identityVerified else { return }
            self.rejectUnregisteredPeripheral(peripheral)
        }
        dataPathStarted = true
        retainKnown(peripheral)
        if let characteristic = peripheral.services?
            .first(where: { $0.uuid == configuration.serviceUUID })?.characteristics?
            .first(where: { $0.uuid == configuration.characteristicUUID }) {
            if let service = characteristic.service, let uuid = configuration.deviceIdentityUUID {
                if let identity = service.characteristics?.first(where: { $0.uuid == uuid }) {
                    readDeviceIdentity(identity, on: peripheral)
                } else {
                    peripheral.discoverCharacteristics([configuration.characteristicUUID, uuid], for: service)
                }
            }
            configureCharacteristic(characteristic, on: peripheral)
        } else {
            setConnectionState(.connecting)
            peripheral.discoverServices([configuration.serviceUUID])
            diagnostic("resuming service discovery id=\(peripheral.identifier)")
        }
    }

    private func readDeviceIdentity(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        guard characteristic.properties.contains(.read) else {
            log("Device identity characteristic is not readable")
            rejectUnregisteredPeripheral(peripheral)
            return
        }
        identityVerificationTask?.cancel()
        identityVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.peripheral === peripheral,
                  !self.identityVerified else { return }
            self.rejectUnregisteredPeripheral(peripheral)
        }
        peripheral.readValue(for: characteristic)
    }

    private func configureCharacteristic(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        guard bindingAllowsConnection, identityVerified, self.peripheral === peripheral, peripheral.state == .connected,
              central.state == .poweredOn,
              characteristic.uuid == configuration.characteristicUUID,
              characteristic.service?.uuid == configuration.serviceUUID else { return }
        guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
            setConnectionState(.error("\(configuration.deviceName) characteristic is not writable."))
            return
        }
        writableCharacteristic = characteristic
        connectedDeviceName = peripheral.name ?? configuration.deviceName
        maximumWriteValueLength = peripheral.maximumWriteValueLength(for: .withResponse)
        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            if characteristic.isNotifying {
                diagnostic("restored notification subscription ready")
                setConnectionState(.connected)
            } else {
                setConnectionState(.connecting)
                peripheral.setNotifyValue(true, for: characteristic)
                diagnostic("notification subscription requested")
            }
        } else {
            setConnectionState(.connected)
        }
    }

    var preferredWriteMode: BLEWriteMode {
        writableCharacteristic?.properties.contains(.write) == true ? .withResponse : .withoutResponse
    }

    /// A firmware restart/service change can invalidate a previously restored handle.
    /// Refresh GATT discovery on the existing connection; never reuse that handle here.
    private func rediscoverDataPath(_ peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, peripheral.state == .connected,
              central.state == .poweredOn, BackgroundReconnectManager.active == nil else { return }
        writableCharacteristic = nil
        connectedDeviceId = nil
        maximumWriteValueLength = nil
        dataPathStarted = true
        setConnectionState(.connecting)
        resumePendingWrite(with: .failure(BLETransportError.notReady(configuration.deviceName)))
        FileLogger.shared.log("[BLE] Rediscovering service and characteristic after invalidation")
        peripheral.discoverServices([configuration.serviceUUID])
    }

    /// One transport write only. Logical fragmentation belongs to MessageBridge.
    func write(_ data: Data, mode: BLEWriteMode) async throws {
        guard BackgroundReconnectManager.active == nil else {
            throw BLETransportError.writeFailed("Payload writes are disabled during the reconnect test.")
        }
        try Task.checkCancellation()
        guard canSend, let peripheral, let characteristic = writableCharacteristic else {
            throw BLETransportError.notReady(configuration.deviceName)
        }

        guard supports(mode, characteristic: characteristic) else {
            throw BLETransportError.unsupportedWriteMode(mode, configuration.deviceName)
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
                pendingWriteCharacteristic = characteristic
                peripheral.writeValue(data, for: characteristic, type: type)
            }
        case .withoutResponse:
            while !peripheral.canSendWriteWithoutResponse {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pendingWithoutResponseContinuation = continuation
                }
                try Task.checkCancellation()
                guard self.peripheral === peripheral, writableCharacteristic === characteristic,
                      canSend else { throw BLETransportError.notReady(configuration.deviceName) }
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
        pendingWriteCharacteristic = nil
        continuation.resume(with: result)
    }

    private func setConnectionState(_ state: ConnectionState) {
        if state == .connected && (!bindingAllowsConnection || !identityVerified) { return }
        connectionState = state
        log("State: \(state.title) - \(state.message(configuration: configuration))")
        connectionStateHandler?(state)
        uiColorConnectionStateHandler?(state)
        viewModeConnectionStateHandler?(state)
        if state == .connected && identityVerified && bindingAllowsConnection && BackgroundReconnectManager.active == nil {
            if configuration.supportsDiagnosticsTimeSync && role == "transit" && !clockSyncStarted { sendClockSync() }
            else if !clockSyncInProgress { readyHandler?(); viewModeReadyHandler?() }
        }
    }

    private func sendClockSync() {
        clockSyncStarted = true
        clockSyncInProgress = true
        if diagnosticSessionId.isEmpty { newDiagnosticSession() }
        let session = diagnosticSessionId
        clockSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.diagnosticSessionId == session {
                    self.clockSyncInProgress = false
                    if self.notificationsReady { self.readyHandler?(); self.viewModeReadyHandler?() }
                }
            }
            do {
                // T2 adds signed local UTC-offset minutes; 16 bytes still fits MTU 23.
                let clockDate = Date()
                let unixMs = UInt64(clockDate.timeIntervalSince1970 * 1000)
                let id = UInt32(session, radix: 16) ?? 1
                var packet = Data([0x54, 0x32])
                for shift in stride(from: 0, to: 64, by: 8) { packet.append(UInt8(truncatingIfNeeded: unixMs >> shift)) }
                for shift in stride(from: 0, to: 32, by: 8) { packet.append(UInt8(truncatingIfNeeded: id >> shift)) }
                let offset = UInt16(bitPattern: Int16(TimeZone.current.secondsFromGMT(for: clockDate) / 60))
                packet.append(UInt8(truncatingIfNeeded: offset))
                packet.append(UInt8(truncatingIfNeeded: offset >> 8))
                PhoneDiagnosticLog.shared.record("TIME_SYNC_SENT", sessionId: session, value1: Int64(unixMs))
                try await self.write(packet, mode: .withResponse)
            } catch {
                PhoneDiagnosticLog.shared.record("TIME_SYNC_FAILED", sessionId: session, level: "WARN", value1: Int64((error as NSError).code))
            }
        }
    }
    private func newDiagnosticSession() {
        diagnosticSessionId = String(format: "%08x", UInt32.random(in: 1...UInt32.max))
        if role == "transit" { PhoneDiagnosticLog.shared.setSession(diagnosticSessionId) }
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

    private func debugClassification(
        peripheralName: String?,
        advertisedName: String?,
        advertisementData: [String: Any]
    ) -> (isRelevant: Bool, shouldConnect: Bool, reason: String) {
        let advertisedServiceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflowServiceUUIDs = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceUUIDs = advertisedServiceUUIDs + overflowServiceUUIDs
        let names = [peripheralName, advertisedName].compactMap { $0 }

        if names.contains(configuration.deviceName) {
            return (true, true, "exact name match")
        }

        if serviceUUIDs.contains(configuration.serviceUUID) {
            return (true, true, "advertises expected service UUID")
        }

        if names.contains(where: { name in
            let lowercasedName = name.lowercased()
            return configuration.relatedNameFragments.contains(where: { lowercasedName.contains($0) })
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
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            diagnostic("willRestoreState invoked")
            FileLogger.shared.log("[BLE] Restoration event role=\(role)")
            let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            for item in restored {
                diagnostic("restored peripheral id=\(item.identifier) state=\(item.state.rawValue)")
            }
            let saved = defaults.string(forKey: knownKey)
            if let known = restored.first(where: { $0.identifier.uuidString == saved }) ?? (restored.count == 1 ? restored.first : nil) {
                retainKnown(known)
                connectionRequestPending = known.state == .connecting
                dataPathStarted = false
                writableCharacteristic = known.services?.first(where: { $0.uuid == configuration.serviceUUID })?
                    .characteristics?.first(where: { $0.uuid == configuration.characteristicUUID })
                diagnostic("reconnect initiated from restored state id=\(known.identifier); waiting for poweredOn if necessary")
            }
            if dict[CBCentralManagerRestoredStateScanServicesKey] != nil {
                diagnostic("restored scan; discovery remains filtered by expected service UUID")
            }
            if central.state == .poweredOn {
                if autoScanEnabled && bindingAllowsConnection { resumeKnownConnection(reason: "restored state") }
                else {
                    stopScanning(reason: "restored manual disconnect intent")
                    if let peripheral {
                        central.cancelPeripheralConnection(peripheral)
                        diagnostic("restored connection cancelled: persisted explicit disconnect")
                    }
                }
            }
        }
    }
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            diagnostic("Central state changed: \(central.state.debugName)")
            backgroundLog("central state: \(central.state.debugName)")

            switch central.state {
            case .poweredOn:
                if case .error = connectionState {
                    setConnectionState(.disconnected)
                }
                if autoScanEnabled && bindingAllowsConnection {
                    resumeKnownConnection(reason: "central poweredOn")
                } else {
                    stopScanning(reason: "persisted manual disconnect intent")
                    if let peripheral, peripheral.state != .disconnected {
                        central.cancelPeripheralConnection(peripheral)
                        diagnostic("restored connection cancelled: persisted explicit disconnect")
                    }
                }
            case .poweredOff:
                connectionRequestPending = false
                dataPathStarted = false
                writableCharacteristic = nil
                connectedDeviceId = nil
                connectionEndedHandler?()
                resumePendingWrite(with: .failure(BLETransportError.notReady(configuration.deviceName)))
                setConnectionState(.error("Bluetooth is turned off."))
            case .unauthorized:
                setConnectionState(.error("Bluetooth permission is not authorized."))
            case .unsupported:
                setConnectionState(.error("Bluetooth LE is not supported on this device."))
            case .resetting:
                connectionRequestPending = false
                retrieveAfterReset = true
                dataPathStarted = false
                writableCharacteristic = nil
                connectedDeviceId = nil
                connectionEndedHandler?()
                resumePendingWrite(with: .failure(BLETransportError.notReady(configuration.deviceName)))
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
            guard bindingAllowsConnection, autoScanEnabled, central.isScanning, self.peripheral == nil,
                  (rejectedCandidates[peripheral.identifier] ?? .distantPast) < Date(),
                  BackgroundReconnectManager.active == nil else { return }
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let classification = self.debugClassification(
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

            PhoneDiagnosticLog.shared.record("BLE_DEVICE_DISCOVERED", value1: Int64(RSSI.intValue))
            if case .connecting = connectionState {
                log("Connect skipped: already connecting")
                return
            }

            if case .connected = connectionState {
                log("Connect skipped: already connected")
                return
            }

            backgroundLog("discovered \(configuration.deviceName): \(peripheral.identifier.uuidString)")
            self.peripheral = peripheral
            peripheral.delegate = self
            setConnectionState(.connecting)
            FileLogger.shared.log("[BLE] Expected peripheral discovered role=\(role)")
            log("Matched \(configuration.deviceName): \(classification.reason)")
            log("Retained peripheral strongly and assigned peripheral.delegate")
            backgroundLog("connect requested")
            log("connect() called for \(peripheral.identifier.uuidString)")
            requestConnection(peripheral, reason: "discovered expected service")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let timestamp = Date()
        MainActor.assumeIsolated {
            clockSyncTask?.cancel(); clockSyncStarted = false; clockSyncInProgress = false
            newDiagnosticSession()
            PhoneDiagnosticLog.shared.record("BLE_CONNECTED", sessionId: diagnosticSessionId)
            connectionRequestPending = false
            log("[E2E] BLE connected; backgrounded=\(UIApplication.shared.applicationState == .background)")
            FileLogger.shared.log("[BLE] Connected role=\(role) backgrounded=\(UIApplication.shared.applicationState == .background)")
        }
        // queue:nil delivers on the main queue; persist evidence inside this callback.
        if MainActor.assumeIsolated({
            if backgroundReconnect.handleConnected(peripheral, at: timestamp) {
                self.peripheral = peripheral
                setConnectionState(.connected)
                return true
            }
            return BackgroundReconnectManager.active != nil
        }) { return }
        MainActor.assumeIsolated {
            guard bindingAllowsConnection, autoScanEnabled, self.peripheral?.identifier == peripheral.identifier else {
                central.cancelPeripheralConnection(peripheral); return
            }
            diagnostic("connected id=\(peripheral.identifier) backgrounded=\(UIApplication.shared.applicationState == .background)")
            resumeDataPath(peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        FileLogger.shared.log("[BLE] Connection failed code=\((error as NSError?)?.code ?? 0)")
        PhoneDiagnosticLog.shared.record("BLE_CONNECT_FAILED", level: "WARN", value1: Int64((error as NSError?)?.code ?? 0))
        if (error as? CBError)?.code == .connectionTimeout {
            FileLogger.shared.log("[BLE] Connection timeout")
        }
        if MainActor.assumeIsolated({
            backgroundReconnect.handleFailure(peripheral, error: error) || BackgroundReconnectManager.active != nil
        }) { return }
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == peripheral.identifier else { return }
            diagnostic("failed connection id=\(peripheral.identifier) error=\(error?.localizedDescription ?? "none")")
            connectionRequestPending = false
            dataPathStarted = false
            writableCharacteristic = nil
            connectedDeviceId = nil
            connectionEndedHandler?()
            resumePendingWrite(with: .failure(BLETransportError.notReady(configuration.deviceName)))
            if autoScanEnabled {
                requestConnection(peripheral, reason: "failed known connection")
            } else {
                setConnectionState(.disconnected)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            handleDisconnect(peripheral, isReconnecting: false, error: error)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                   timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        MainActor.assumeIsolated {
            diagnostic("disconnect timestamp=\(timestamp) systemReconnecting=\(isReconnecting)")
            handleDisconnect(peripheral, isReconnecting: isReconnecting, error: error)
        }
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, isReconnecting: Bool, error: Error?) {
        PhoneDiagnosticLog.shared.record("BLE_DISCONNECTED", sessionId: diagnosticSessionId, value1: Int64((error as NSError?)?.code ?? 0))
        clockSyncTask?.cancel(); clockSyncStarted = false; clockSyncInProgress = false
        FileLogger.shared.log("[BLE] Disconnected role=\(role) code=\((error as NSError?)?.code ?? 0) reconnecting=\(isReconnecting)")
        diagnostic("disconnected id=\(peripheral.identifier) error=\(error?.localizedDescription ?? "none")")
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        retainKnown(peripheral)
        connectionRequestPending = isReconnecting
        dataPathStarted = false
        writableCharacteristic = nil
        connectedDeviceId = nil
        connectedDeviceName = nil
        maximumWriteValueLength = nil
        connectionEndedHandler?()
        resumePendingWrite(with: .failure(BLETransportError.notReady(configuration.deviceName)))
        guard autoScanEnabled, !userRequestedDisconnect else {
            setConnectionState(.disconnected)
            return
        }
        if BackgroundReconnectManager.active != nil {
            if backgroundReconnect.handleDisconnect(peripheral, systemReconnecting: isReconnecting) {
                setConnectionState(.connecting)
            } else { setConnectionState(.disconnected) }
            return
        }
        if isReconnecting {
            stopScanning(reason: "system reconnect pending")
            setConnectionState(.connecting)
            diagnostic("connection pending: system-managed reconnect; no duplicate connect request")
        } else {
            requestConnection(peripheral, reason: "known peripheral disconnected")
        }
    }
}

extension BluetoothService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral,
                  invalidatedServices.contains(where: { $0.uuid == configuration.serviceUUID }) else { return }
            rediscoverDataPath(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard self.peripheral === peripheral, peripheral.state == .connected,
                  BackgroundReconnectManager.active == nil else { return }
            if let error {
                log("Service discovery failed: \(error.localizedDescription)")
                rejectUnregisteredPeripheral(peripheral)
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

            guard let service = peripheral.services?.first(where: { $0.uuid == configuration.serviceUUID }) else {
                rejectUnregisteredPeripheral(peripheral)
                return
            }

            log("Discovering characteristic \(configuration.characteristicUUID.uuidString)")
            peripheral.discoverCharacteristics([configuration.characteristicUUID] + [configuration.deviceIdentityUUID].compactMap { $0 }, for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.peripheral === peripheral, peripheral.state == .connected,
                  BackgroundReconnectManager.active == nil else { return }
            if let error {
                log("Characteristic discovery failed: \(error.localizedDescription)")
                rejectUnregisteredPeripheral(peripheral)
                return
            }

            let characteristics = service.characteristics?.map { characteristic in
                "\(characteristic.uuid.uuidString) [\(characteristic.properties.debugNames)]"
            }.joined(separator: ", ") ?? "none"
            guard BackgroundReconnectManager.active == nil else { return }
            log("Discovered characteristics: \(characteristics)")
            guard service.uuid == configuration.serviceUUID else { return }
            if let uuid = configuration.deviceIdentityUUID {
                if let identity = service.characteristics?.first(where: { $0.uuid == uuid }) {
                    readDeviceIdentity(identity, on: peripheral)
                } else {
                    log("Device identity unavailable; cannot verify registered TrainPod")
                    rejectUnregisteredPeripheral(peripheral)
                    return
                }
            }

            guard let characteristic = service.characteristics?.first(where: { $0.uuid == configuration.characteristicUUID }) else {
                rejectUnregisteredPeripheral(peripheral)
                return
            }

            configureCharacteristic(characteristic, on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Capture callback data before hopping to the main actor; the characteristic is mutable.
        let received = characteristic.value
        if MainActor.assumeIsolated({
            guard peripheral === self.peripheral,
                  peripheral.state == .connected,
                  let uuid = configuration.deviceIdentityUUID,
                  characteristic.uuid == uuid,
                  characteristic.service?.uuid == configuration.serviceUUID else { return false }
            if let error {
                log("Device identity read failed: \(error.localizedDescription)")
                rejectUnregisteredPeripheral(peripheral)
                return true
            }
            guard let received, let id = String(data: received, encoding: .utf8),
                  id.range(of: "^TP-(?:[0-9A-F]{8}|[0-9A-F]{32})$", options: .regularExpression) != nil else {
                log("Device identity read returned an invalid value")
                rejectUnregisteredPeripheral(peripheral)
                return true
            }
            guard id == TrainPodBindingStore.shared.bound?.deviceId else {
                rejectUnregisteredPeripheral(peripheral); return true
            }
            identityVerificationTask?.cancel()
            connectedDeviceId = id
            retainKnown(peripheral)
            FileLogger.shared.log("[BLE] Connected TrainPod ID: \(id)")
            if let transfer = characteristic.service?.characteristics?.first(where: { $0.uuid == configuration.characteristicUUID }) {
                configureCharacteristic(transfer, on: peripheral)
            }
            return true
        }) { return }
        if MainActor.assumeIsolated({
            guard bindingAllowsConnection, identityVerified, peripheral === self.peripheral, characteristic === writableCharacteristic,
                  error == nil,
                  received.map({ configuration.controlMessages.contains($0) || PayloadDelivery.request($0) != nil }) == true else { return false }
            // Control messages are not ACKs or test frames. Consume in both service instances;
            // only the product owner installs the response handler.
            let timestamp = Date()
            let backgrounded = UIApplication.shared.applicationState == .background
            let transaction = received.flatMap(PayloadDelivery.request)
            let ignored = BackgroundReconnectManager.active != nil
            recentDeviceRequests.insert(ReceivedDeviceRequest(receivedAt: timestamp,
                name: transaction != nil ? "NEED_DATA (P1)" : String(decoding: received ?? Data(), as: UTF8.self),
                transactionID: transaction?.id, byteCount: received?.count ?? 0,
                backgrounded: backgrounded, ignored: ignored), at: 0)
            if recentDeviceRequests.count > 50 { recentDeviceRequests.removeLast(recentDeviceRequests.count - 50) }
            guard BackgroundReconnectManager.active == nil else {
                log(configuration.ignoredControlMessage)
                return true
            }
            controlMessageHandler?(timestamp, backgrounded, transaction)
            return true
        }) { return }
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

            if data.starts(with: Data("VA:".utf8)) {
                viewModeAcknowledgementHandler?(data)
            } else if data.starts(with: Data("UA:".utf8)) || data.starts(with: Data("TA:".utf8)) {
                uiColorAcknowledgementHandler?(data)
            } else if let (transaction, status, bytes) = PayloadDelivery.acknowledgement(data) {
                dataAppliedHandler?(transaction, status, bytes)
            } else if DiagnosticPacket.isDiagnostic(data) { diagnosticDataHandler?(data) }
            else { receivedDataHandler?(data) }
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
        // queue:nil delivers this on main. Process before a later connection event
        // can install a different pending write or characteristic.
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral,
                  pendingWriteCharacteristic === characteristic,
                  pendingWriteContinuation != nil else {
                FileLogger.shared.log("[BLE] Ignored obsolete write callback")
                return
            }
            if let error {
                FileLogger.shared.log("[BLE] Write failed code=\((error as NSError).code)")
                log("Write response failed: \(error.localizedDescription)")
                resumePendingWrite(with: .failure(BLETransportError.writeFailed(error.localizedDescription)))
                if let code = (error as? CBError)?.code,
                   code == .uuidNotAllowed || code == .invalidHandle {
                    rediscoverDataPath(peripheral)
                }
                // A failed transaction does not itself mean BLE disconnected.
                // Keep valid connections usable for the device's next request.
            } else {
                log("Write response received for \(characteristic.uuid.uuidString)")
                resumePendingWrite(with: .success(()))
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.peripheral === peripheral, canSend,
                  let continuation = pendingWithoutResponseContinuation else {
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
