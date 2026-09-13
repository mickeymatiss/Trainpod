import Combine
import Foundation
import SwiftUI

/// Selection is local; only a matching persistence ACK confirms device state.
@MainActor
final class DeviceUIColor: ObservableObject {
    enum PushState: Equatable { case idle, sending, success, failed(String) }
    @Published var selectedThemeID = "book_tan" {
        didSet {
            if pushState != .sending { pushState = .idle }
            if selectedThemeID != oldValue { requestLiveUpdate() }
        }
    }
    @Published private(set) var customTheme = DeviceTheme.loadCustom()
    @Published private(set) var themeEdits: [String: DeviceTheme] = {
        guard let data = UserDefaults.standard.data(forKey: "deviceTheme.edits.v1"),
              let saved = try? JSONDecoder().decode([String: DeviceTheme].self, from: data) else { return [:] }
        return saved.filter { id, theme in
            id == theme.id && theme.colors.allSatisfy { hex in
                let bytes = Array(hex.utf8)
                return bytes.count == 7 && bytes.first == 35 && bytes.dropFirst().allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }
            }
        }
    }()
    var themes: [DeviceTheme] {
        var options = DeviceTheme.presets
        options.insert(customTheme, at: 8) // Replaces Sunset Punch in the grid.
        return options.map { themeEdits[$0.id] ?? $0 }
    }
    var selectedTheme: DeviceTheme {
        themes.first { $0.id == selectedThemeID } ?? DeviceTheme.presets[2]
    }
    func setSelectedColor(_ color: Color, at keyPath: WritableKeyPath<DeviceTheme, String>) {
        guard let hex = DeviceTheme.hex(color), selectedTheme[keyPath: keyPath] != hex else { return }
        var theme = selectedTheme
        theme[keyPath: keyPath] = hex
        saveEdit(theme)
    }
    func renameSelectedTheme(_ name: String) {
        var theme = selectedTheme
        theme.name = String(name.prefix(40))
        saveEdit(theme)
    }
    private func saveEdit(_ theme: DeviceTheme) {
        let colorsChanged = selectedTheme.colors != theme.colors
        themeEdits[theme.id] = theme
        if pushState != .sending { pushState = .idle }
        if let data = try? JSONEncoder().encode(themeEdits) {
            UserDefaults.standard.set(data, forKey: "deviceTheme.edits.v1")
        }
        if colorsChanged { requestLiveUpdate() }
    }
    @Published var liveEnabled = false {
        didSet {
            liveUpdateTask?.cancel()
            liveUpdateTask = nil
            liveNeedsSend = false
            lastLiveColors = selectedTheme.colors
            // Enabling live editing does not itself change the device.
        }
    }
    private var liveReadinessObservation: AnyCancellable?
    private var lastLiveColors: [String] = []
    private var liveNeedsSend = false
    private var liveUpdateTask: Task<Void, Never>?
    private func requestLiveUpdate() {
        guard liveEnabled else { return }
        let colors = selectedTheme.colors
        guard colors != lastLiveColors else { return }
        lastLiveColors = colors
        // If an edit returns to the in-flight value, drop any superseded edit.
        // Otherwise compare with the last value acknowledged by the device.
        let target = pendingToken != nil ? pendingTheme : deviceTheme
        liveNeedsSend = target?.colors != colors
        if liveNeedsSend { scheduleLiveUpdate() }
    }
    private func scheduleLiveUpdate() {
        guard liveEnabled, liveNeedsSend, liveUpdateTask == nil else { return }
        liveUpdateTask = Task { [weak self] in
            // No timed throttle: send the latest palette as soon as transport and
            // the previous persistence acknowledgement allow another transaction.
            guard !Task.isCancelled, let self else { return }
            self.liveUpdateTask = nil
            guard self.liveEnabled, self.liveNeedsSend else { return }
            if self.pushState == .sending { return } // ACK schedules only a changed value.
            if self.deviceTheme?.colors == self.selectedTheme.colors {
                self.liveNeedsSend = false
                return
            }
            guard self.bluetooth.notificationsReady else {
                self.liveEnabled = false
                return
            }
            // Readiness/bridge callbacks resume this pending edit without polling.
            guard self.bridge.canSend, !self.bridge.isSending else { return }
            self.liveNeedsSend = false
            self.push()
        }
    }

    @Published private(set) var deviceTheme: DeviceTheme?
    @Published private(set) var pushState: PushState = .idle
    private let bluetooth: BluetoothService
    private let bridge: MessageBridge
    private var pendingToken: String?
    private var pendingTheme: DeviceTheme?
    private var timeoutTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    init(bluetooth: BluetoothService, bridge: MessageBridge) {
        self.bluetooth = bluetooth
        self.bridge = bridge
        bridge.controlSendReadyHandler = { [weak self] in self?.scheduleLiveUpdate() }
        liveReadinessObservation = bluetooth.objectWillChange.sink { [weak self] _ in
            self?.scheduleLiveUpdate()
        }
        bluetooth.uiColorAcknowledgementHandler = { [weak self] in self?.receive($0) }
        bluetooth.uiColorConnectionStateHandler = { [weak self] state in
            guard state != .connected, let self else { return }
            self.liveEnabled = false
            guard self.pendingToken != nil else { return }
            self.fail("Connection ended before confirmation. Hold the device button for two seconds, then retry when connected.")
        }
    }
    deinit { timeoutTask?.cancel(); sendTask?.cancel(); liveUpdateTask?.cancel() }
    var canPush: Bool { pushState != .sending && bluetooth.notificationsReady && bridge.canSend }

    func push() {
        guard pushState != .sending else { return }
        guard canPush else {
            pushState = .failed("Device is not ready or is busy. Try again shortly.")
            return
        }
        let theme = selectedTheme
        let token = String(UUID().uuidString.prefix(8)).uppercased()
        pendingToken = token
        pendingTheme = theme
        pushState = .sending
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.pendingToken == token else { return }
            self.fail("No theme confirmation. Check the connection and update the device firmware, then retry.")
        }
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Every packet fits the minimum 20-byte ATT payload. The bridge
                // reserves the whole sequence so transit writes cannot interleave.
                var commands = theme.colors.enumerated().map { index, hex in
                    Data("UT:\(token):\(index):\(hex.dropFirst())".utf8)
                }
                commands.append(Data("UT:\(token):C".utf8))
                try await self.bridge.sendControls(commands)
            } catch {
                guard self.pendingToken == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func receive(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "TA",
              let token = pendingToken, String(fields[1]) == token,
              let theme = pendingTheme else { return }
        let result = String(fields[2])
        if result == theme.fingerprint {
            timeoutTask?.cancel()
            pendingToken = nil
            pendingTheme = nil
            deviceTheme = theme
            pushState = .success
            scheduleLiveUpdate()
        } else {
            let message: String
            switch result {
            case "E1": message = "The device rejected an incomplete or invalid theme. Please retry."
            case "E2": message = "The device could not save the theme. Its previous theme is still active."
            case "E3": message = "The device is busy. Please retry."
            default: message = "The device confirmed different theme colors. Please retry."
            }
            fail(message)
        }
    }
    private func fail(_ message: String) {
        liveEnabled = false
        timeoutTask?.cancel()
        sendTask?.cancel()
        pendingToken = nil
        pendingTheme = nil
        pushState = .failed(message)
    }
}
