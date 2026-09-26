import Foundation
import Combine

// Controller-only doubles: no CoreBluetooth objects or BLE algorithm is modeled.
@MainActor final class BluetoothService: ObservableObject {
    enum ConnectionState: Equatable { case connected, disconnected, connecting }
    @Published var notificationsReady = true
    var uiColorAcknowledgementHandler: ((Data) -> Void)?
    var uiColorConnectionStateHandler: ((ConnectionState) -> Void)?
}
@MainActor final class MessageBridge {
    var controlSendReadyHandler: (() -> Void)?
    var canSend = true
    var isSending = false
    var sends: [[Data]] = []
    func sendControls(_ commands: [Data]) async throws { sends.append(commands) }
}
