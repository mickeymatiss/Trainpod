import Combine
import Foundation

@MainActor
final class DeviceDisplayMode: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case standard = "0", compact = "1"
        var id: String { rawValue }
        var title: String { self == .compact ? "Compact" : "Standard" }
    }
    @Published var selected: Mode = .standard {
        didSet {
            if selected != oldValue && !busy { status = nil; failed = false }
        }
    }
    @Published private(set) var confirmed: Mode?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var failed = false
    private let bluetooth: BluetoothService
    private let bridge: MessageBridge
    private var requested = false
    private var deviceID: String?
    private var pendingToken: String?
    private var pendingMode: Mode?
    private var timeout: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var readiness: AnyCancellable?

    init(bluetooth: BluetoothService, bridge: MessageBridge) {
        self.bluetooth = bluetooth
        self.bridge = bridge
        if let id = TrainPodBindingStore.shared.bound?.deviceId {
            deviceID = id
            selected = Self.cached(id)
        }
        bluetooth.viewModeAcknowledgementHandler = { [weak self] in self?.receive($0) }
        bluetooth.viewModeConnectionStateHandler = { [weak self] state in
            guard state != .connected, let self else { return }
            if self.busy { self.finish(error: "Connection ended before confirmation. Reconnect to read the saved mode.") }
            self.confirmed = nil
            self.requested = false
        }
        bluetooth.viewModeReadyHandler = { [weak self] in self?.scheduleRead() }
        bridge.viewModeSendReadyHandler = { [weak self] in self?.scheduleRead() }
        readiness = bluetooth.objectWillChange.sink { [weak self] _ in self?.scheduleRead() }
    }
    deinit { timeout?.cancel(); sender?.cancel() }

    // The nearby-arrivals view follows confirmed device state, including offline.
    // The customization preview can show an unsaved selection independently.
    var active: Mode { confirmed ?? deviceID.map(Self.cached) ?? .standard }
    var canSend: Bool { !busy && bluetooth.notificationsReady && bridge.canSend && !bridge.isSending }
    var canSave: Bool { canSend && confirmed != nil && selected != confirmed }

    private static func cached(_ id: String) -> Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: "displayMode.\(id)") ?? "0") ?? .standard
    }
    private func scheduleRead() {
        // objectWillChange precedes the new value. Defer until it is available.
        Task { @MainActor [weak self] in
            guard let self, !self.requested, self.canSend,
                  let id = self.bluetooth.connectedDeviceId else { return }
            if self.deviceID != id {
                self.deviceID = id
                self.selected = Self.cached(id)
                self.confirmed = nil
            }
            self.read()
        }
    }
    func read() {
        guard canSend else { return }
        requested = true
        send(nil)
    }
    func save(finishingSetup: Bool = false) {
        guard finishingSetup ? (canSend && confirmed != nil) : canSave else { return }
        send(selected, finishingSetup: finishingSetup)
    }
    private func send(_ mode: Mode?, finishingSetup: Bool = false) {
        let token = String(UUID().uuidString.prefix(8)).uppercased()
        pendingToken = token
        pendingMode = mode
        busy = true
        failed = false
        status = mode == nil ? "Reading TrainPod mode…" : "Saving mode…"
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.pendingToken == token else { return }
            self.finish(error: "No mode confirmation. Reconnect or update the TrainPod firmware, then retry.")
        }
        // 2/3 atomically finish setup after saving standard/compact mode.
        // The VA response confirms both operations; old firmware rejects it.
        let value = finishingSetup ? (mode == .compact ? "3" : "2") : (mode?.rawValue ?? "?")
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bridge.sendControls([Data("VM:\(token):\(value)".utf8)])
            } catch {
                guard self.pendingToken == token else { return }
                self.finish(error: error.localizedDescription)
            }
        }
    }
    private func receive(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "VA", let token = pendingToken,
              fields[1] == Substring(token) else { return }
        guard let mode = Mode(rawValue: String(fields[2])) else {
            finish(error: fields[2] == "E2" ? "TrainPod could not save this mode. Its previous mode is still active."
                   : "TrainPod could not accept the mode request. Please retry.")
            return
        }
        guard pendingMode == nil || pendingMode == mode else {
            finish(error: "TrainPod confirmed a different mode. Read its saved mode and retry.")
            return
        }
        let wasSave = pendingMode != nil
        timeout?.cancel()
        pendingToken = nil
        pendingMode = nil
        confirmed = mode
        selected = mode
        if let id = bluetooth.connectedDeviceId {
            deviceID = id
            if UserDefaults.standard.string(forKey: "displayMode.\(id)") != mode.rawValue {
                UserDefaults.standard.set(mode.rawValue, forKey: "displayMode.\(id)")
            }
        }
        busy = false
        failed = false
        status = wasSave ? "Saved on TrainPod" : "TrainPod is in \(mode.title.lowercased()) mode"
        FileLogger.shared.log("[BLE] TrainPod display mode: \(mode.title.lowercased())")
    }
    private func finish(error: String) {
        timeout?.cancel()
        sender?.cancel()
        pendingToken = nil
        pendingMode = nil
        busy = false
        failed = true
        status = error
    }
}
