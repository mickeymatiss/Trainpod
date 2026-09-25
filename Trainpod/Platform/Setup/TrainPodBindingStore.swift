import Combine
import Foundation
import Security

struct TrainPodBinding: Codable, Equatable {
    let deviceId: String
    let appInstallationId: UUID
    let bindingKey: Data
    var peripheralIdentifier: UUID?
}

/// One atomic Keychain item contains installation identity, pending, active and saved devices.
/// Pending setup may be paused while a different saved device is active.
/// Pending credentials reach durable storage BEFORE any claim leaves this phone.
@MainActor
final class TrainPodBindingStore: ObservableObject {
    static let shared = TrainPodBindingStore()
    private struct State: Codable {
        var appInstallationId: UUID
        var pending: TrainPodBinding?
        var bound: TrainPodBinding?
        var saved: [TrainPodBinding]? // Optional for migration from single-device records.
    }
    enum Failure: LocalizedError {
        case keychain(OSStatus), invalidRecord, pendingOtherDevice
        var errorDescription: String? {
            switch self {
            case .keychain: return "Binding storage is unavailable. Unlock your iPhone and retry."
            case .invalidRecord: return "Stored TrainPod binding could not be read. It has been preserved."
            case .pendingOtherDevice: return "Finish setup with the TrainPod already being registered."
            }
        }
    }
    @Published private(set) var bound: TrainPodBinding?
    @Published private(set) var pending: TrainPodBinding?
    @Published private(set) var savedBindings: [TrainPodBinding] = []
    @Published private(set) var storageError: String?
    private var state: State?
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.trainpod.local-binding.v1",
        kSecAttrAccount as String: "installation",
        kSecAttrSynchronizable as String: false
    ]
    private init() { reload() }
    static func validDeviceId(_ id: String) -> Bool {
        (id.count == 35 || id.count == 11) && id.hasPrefix("TP-") &&
        id.dropFirst(3).utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }
    func reload() {
        do {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound {
                try save(State(appInstallationId: UUID()))
            } else {
                guard status == errSecSuccess else { throw Failure.keychain(status) }
                guard let data = result as? Data, let value = try? JSONDecoder().decode(State.self, from: data) else { throw Failure.invalidRecord }
                let bindings = [value.pending, value.bound].compactMap({ $0 }) + (value.saved ?? [])
                guard Set(bindings.map(\.deviceId)).count == bindings.count else { throw Failure.invalidRecord }
                for binding in bindings {
                    guard Self.validDeviceId(binding.deviceId), binding.bindingKey.count == 32,
                          binding.appInstallationId == value.appInstallationId else { throw Failure.invalidRecord }
                }
                publish(value)
            }
        } catch { state = nil; bound = nil; pending = nil; savedBindings = []; storageError = error.localizedDescription }
    }
    private func publish(_ value: State) {
        state = value; pending = value.pending; savedBindings = value.saved ?? []; bound = value.bound; storageError = nil
    }
    private func save(_ value: State) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        publish(value)
    }
    func prepare(deviceId: String, peripheral: UUID) throws -> TrainPodBinding {
        guard var value = state, value.bound == nil, Self.validDeviceId(deviceId),
              !(value.saved ?? []).contains(where: { $0.deviceId == deviceId }) else { throw Failure.invalidRecord }
        if let pending = value.pending {
            guard pending.deviceId == deviceId else { throw Failure.pendingOtherDevice }
            return pending
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        let binding = TrainPodBinding(deviceId: deviceId, appInstallationId: value.appInstallationId,
                                      bindingKey: Data(bytes), peripheralIdentifier: peripheral)
        value.pending = binding
        try save(value)
        return binding
    }
    func promote(deviceId: String, peripheral: UUID) throws {
        guard var value = state, value.bound == nil, var binding = value.pending, binding.deviceId == deviceId else { throw Failure.invalidRecord }
        binding.peripheralIdentifier = peripheral
        value.bound = binding; value.pending = nil
        try save(value)
    }
    /// Save the current device locally and enter (or resume) setup for another.
    /// Installation identity and device credentials stay unchanged. No BLE writes.
    func beginAdditionalDeviceSetup() throws {
        guard var value = state, let current = value.bound else { throw Failure.invalidRecord }
        var saved = value.saved ?? []
        saved.removeAll { $0.deviceId == current.deviceId }
        saved.insert(current, at: 0)
        value.saved = saved
        value.bound = nil
        try save(value)
    }

    /// Switching is local, even while the selected device is offline. Retain any
    /// pending claim so returning to setup can recover the same credentials.
    func activateSavedDevice(deviceId: String) throws {
        guard var value = state, var saved = value.saved,
              let index = saved.firstIndex(where: { $0.deviceId == deviceId }) else { throw Failure.invalidRecord }
        let selected = saved.remove(at: index)
        if let current = value.bound { saved.insert(current, at: 0) }
        value.saved = saved
        value.bound = selected
        try save(value)
    }

    /// Use only after the developer reset has confirmed the active device is unprovisioned.
    /// Other devices retain their credentials and shared installation identity.
    func resetInstallationForDevelopment() throws {
        guard var value = state else { throw Failure.invalidRecord }
        value.bound = nil
        if (value.saved ?? []).isEmpty && value.pending == nil {
            value = State(appInstallationId: UUID())
        }
        try save(value)
    }

    /// Local-only deletion; does not unbind the firmware or erase permanent ID.
    func clearBinding() throws {
        guard var value = state else { throw Failure.invalidRecord }
        value.bound = nil; value.pending = nil; try save(value)
    }
}
